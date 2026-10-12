#!/bin/bash
# failover.sh — сторож: держит AWG-туннель в таблице PBR UniFi и переключает каналы.
#   failover.sh            основной цикл (запускает systemd: awg-failover.service)
#   failover.sh cleanup    убрать свои маршруты из таблицы PBR
# Параметры: /data/awg/awg.env (создаёт awg-detect.sh).
# Ручное управление (пишет бот Telegram или вы сами): /data/awg/control
#   MODE=auto|main|backup|off   auto — как обычно; main/backup — держать этот канал, пока он жив,
#                               при его падении всё равно спасаться на другой; off — каналы остановлены
#   OFF_ACTION=block|wan        что делать с PBR-трафиком при MODE=off: блокировать или пустить через провайдера
#   DISABLED="awgbackup"        остановленные каналы: интерфейс удаляется, сторож его не поднимает
DD=${DD:-/data/awg}
iptables(){ command iptables -w 10 "$@"; }   # hotfix: ждать xtables lock, а не падать (иначе ensure плодит копии)
RS_ENV=$RECOVER_SEC                # RECOVER_SEC из командной строки важнее awg.env (для тестов)
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
[ -n "$RS_ENV" ] && RECOVER_SEC=$RS_ENV
TABLE=${TABLE:?нет TABLE в awg.env: запустите awg-detect.sh}
MARK=${MARK:?нет MARK в awg.env: запустите awg-detect.sh}
PRIO=${PRIO:-32504}
MAIN=${MAIN:-awgmain}
BACKUP=${BACKUP:-}
RECOVER_SEC=${RECOVER_SEC:-600}   # сколько основной должен проработать без сбоев до возврата
TARGETS=${TARGETS:-"1.1.1.1 8.8.8.8"}
INTERVAL=${INTERVAL:-5}           # секунд между проверками
FAIL_MAX=${FAIL_MAX:-3}           # сбоев подряд до переключения
METRIC=5                          # метрика активного туннеля в таблице PBR
SIM=/tmp/awg-sim-down             # флаг имитации падения основного канала
LOGF=$DD/failover.log
CTL=$DD/control

log(){
  local m; m="$(date '+%F %T') $*"
  echo "$m"; logger -t awg-failover "$*" 2>/dev/null; echo "$m" >> "$LOGF"
  if [ "$(wc -l < "$LOGF")" -gt 1000 ]; then tail -n 500 "$LOGF" > "$LOGF.tmp" && mv "$LOGF.tmp" "$LOGF"; fi
}

# Канал жив, если через него открывается HTTPS (или, если не открылся, проходит ping).
# Первым идёт HTTPS: ICMP через туннели многих операторов не проходит.
check(){
  [ "$1" = "$MAIN" ] && [ -e "$SIM" ] && return 1
  local t c
  for t in $TARGETS; do
    c=$(curl -sk -o /dev/null --connect-timeout 3 -m 5 --interface "$1" -w '%{http_code}' "https://$t/" 2>/dev/null)
    [ -n "$c" ] && [ "$c" != 000 ] && return 0
    ping -I "$1" -c 1 -W 2 "$t" >/dev/null 2>&1 && return 0
  done
  return 1
}

ensure(){ local t=$1; shift; iptables -t "$t" -C "$@" 2>/dev/null || iptables -t "$t" -I "$@"; }

prepare(){
  local i s
  for i in $MAIN $BACKUP; do
    ensure nat POSTROUTING -o "$i" -j MASQUERADE
    ensure mangle FORWARD -o "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ensure mangle FORWARD -i "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ensure filter FORWARD -o "$i" -j ACCEPT
    ensure filter FORWARD -i "$i" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  done
  ip rule show | grep -q "fwmark $MARK" || ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO"
  # дополнительные подсети (например, клиенты VPN-сервера роутера) в ipset локальных сетей UniFi
  for s in $EXTRA_SUBNETS; do
    ipset test UBIOS4local_network "$s" >/dev/null 2>&1 || ipset add UBIOS4local_network "$s" 2>/dev/null
  done
}

declare -A NEXT_TRY
ensure_tunnels(){
  local i now; now=$(date +%s)
  for i in $MAIN $BACKUP; do
    enabled "$i" || continue
    ip link show "$i" >/dev/null 2>&1 && continue
    [ "${NEXT_TRY[$i]:-0}" -gt "$now" ] && continue
    NEXT_TRY[$i]=$((now + 30))
    log "$i отсутствует, поднимаю"
    "$DD/up.sh" "$i" >/dev/null 2>&1 || log "$i: не удалось поднять (проверьте: $DD/up.sh $i)"
  done
}

set_active(){
  local a=$1 o
  for o in $MAIN $BACKUP; do [ "$o" = "$a" ] || ip route del default dev "$o" table "$TABLE" 2>/dev/null; done
  ip route replace default dev "$a" metric $METRIC table "$TABLE"
  ip route replace blackhole default metric 200 table "$TABLE" 2>/dev/null
}

# каналы остановлены вручную: block — только blackhole (PBR-трафик стоит), wan — таблица пуста (трафик идёт мимо туннеля)
set_off(){
  local o
  for o in $MAIN $BACKUP; do ip route del default dev "$o" table "$TABLE" 2>/dev/null; done
  if [ "$OFF_ACTION" = wan ]; then ip route del blackhole default metric 200 table "$TABLE" 2>/dev/null
  else ip route replace blackhole default metric 200 table "$TABLE" 2>/dev/null; fi
}

# shellcheck disable=SC1090
ctl_load(){ MODE=auto; OFF_ACTION=block; DISABLED=""; [ -r "$CTL" ] && . "$CTL"; case "$MODE" in auto|main|backup|off) ;; *) MODE=auto;; esac; }
enabled(){ [ -n "$1" ] && case " $DISABLED " in *" $1 "*) return 1;; esac; }
stop_disabled(){
  local i
  for i in $MAIN $BACKUP; do
    enabled "$i" && continue
    NEXT_TRY[$i]=0                      # после включения канал поднимется сразу
    ip link show "$i" >/dev/null 2>&1 || continue
    ip link del "$i" 2>/dev/null; pkill -f "amneziawg-go $i\$" 2>/dev/null
    log "канал $i остановлен вручную"
  done
}

cleanup(){
  ip route del default dev "$MAIN" table "$TABLE" 2>/dev/null
  [ -n "$BACKUP" ] && ip route del default dev "$BACKUP" table "$TABLE" 2>/dev/null
  ip route del blackhole default metric 200 table "$TABLE" 2>/dev/null
}

[ "$1" = cleanup ] && { cleanup; exit 0; }
trap 'cleanup; log "остановка: маршруты убраны"; exit 0' INT TERM

# после загрузки роутера даём UniFi 30 с собрать свои правила и таблицы
[ "$(cut -d. -f1 /proc/uptime)" -lt 300 ] && sleep "${BOOT_WAIT:-30}"

ctl_load
state=""; fails=0; bfails=0; ok_since=0; both_flag=0; offstate=""; lastmode=""
log "старт: основной $MAIN, запасной ${BACKUP:-нет}, таблица $TABLE, возврат через ${RECOVER_SEC}с, режим $MODE${DISABLED:+, остановлены: $DISABLED}"

while true; do
  ctl_load
  stop_disabled
  ensure_tunnels
  prepare

  # P — предпочтительный канал режима, O — запасной для него (если есть и не остановлен)
  case "$MODE" in backup) P=$BACKUP;; *) P=$MAIN;; esac
  enabled "$P" || { if enabled "$MAIN"; then P=$MAIN; elif enabled "$BACKUP"; then P=$BACKUP; else P=""; fi; }
  O=""; for i in $MAIN $BACKUP; do [ "$i" != "$P" ] && enabled "$i" && O=$i; done

  if [ "$MODE" = off ] || [ -z "$P" ]; then
    if [ "$offstate" != "$OFF_ACTION" ]; then
      if [ "$OFF_ACTION" = wan ]; then log "РУЧНОЙ РЕЖИМ: каналы остановлены, PBR-трафик идёт через провайдера"
      else log "РУЧНОЙ РЕЖИМ: каналы остановлены, PBR-трафик блокируется"; fi
      offstate=$OFF_ACTION
    fi
    set_off; lastmode=off; sleep "$INTERVAL"; continue
  fi
  [ -n "$offstate" ] && { log "РУЧНОЙ РЕЖИМ: каналы снова работают"; offstate=""; }

  # смена режима или текущий канал остановлен: сразу на предпочтительный, если он жив
  if [ "$MODE" != "$lastmode" ] || ! enabled "$state"; then
    if [ "$state" != "$P" ] && { [ -z "$state" ] || ! enabled "$state" || check "$P"; }; then
      [ -n "$lastmode" ] && log "РУЧНОЙ РЕЖИМ: $MODE, канал $P"
      state=$P; fails=0; bfails=0; ok_since=0; both_flag=0
    elif [ -n "$lastmode" ]; then
      log "РУЧНОЙ РЕЖИМ: $MODE"
    fi
    lastmode=$MODE
  fi
  RS=$RECOVER_SEC; [ "$MODE" != auto ] && RS=0     # в ручном режиме возврат на выбранный канал сразу

  if [ "$state" = "$P" ]; then
    if check "$P"; then
      [ $both_flag -eq 1 ] && log "ВОССТАНОВЛЕН канал $P, трафик по PBR снова идёт"
      fails=0; both_flag=0
    else
      fails=$((fails+1))
    fi
    if [ $fails -ge $FAIL_MAX ]; then
      if [ -n "$O" ] && check "$O"; then
        state=$O; fails=0; bfails=0; ok_since=0; both_flag=0
        if [ "$O" = "$BACKUP" ]; then log "ПЕРЕКЛЮЧЕНИЕ на запасной канал $O"; else log "ПЕРЕКЛЮЧЕНИЕ на основной канал $O (выбранный $P не отвечает)"; fi
      elif [ $both_flag -eq 0 ]; then
        both_flag=1
        if [ -n "$O" ]; then log "оба канала не отвечают, остаюсь на $P (трафик по PBR блокируется)"
        else log "единственный канал $P не отвечает (трафик по PBR блокируется)"; fi
      fi
    fi
  else
    if check "$P"; then
      [ $ok_since -eq 0 ] && { ok_since=$(date +%s); [ "$RS" -gt 0 ] && log "основной снова отвечает, жду ${RS}с без сбоев"; }
      if [ $(( $(date +%s) - ok_since )) -ge "$RS" ]; then
        state=$P; fails=0; ok_since=0
        if [ "$P" = "$MAIN" ]; then log "ВОЗВРАТ на основной канал $MAIN"; else log "ВОЗВРАТ на выбранный канал $P"; fi
      fi
    else
      [ $ok_since -ne 0 ] && [ "$RS" -gt 0 ] && log "основной снова сбоит, отсчёт возврата сброшен"
      ok_since=0
    fi
    if [ "$state" != "$P" ]; then
      if check "$state"; then bfails=0; else bfails=$((bfails+1)); fi
      if [ $bfails -ge $FAIL_MAX ] && check "$P"; then
        state=$P; fails=0; bfails=0; ok_since=0
        log "запасной не отвечает, основной жив: возврат на $P"
      fi
    fi
  fi

  set_active "$state"
  sleep "$INTERVAL"
done
