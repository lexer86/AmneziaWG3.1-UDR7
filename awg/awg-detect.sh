#!/bin/bash
# awg-detect.sh — находит PBR-обвязку UniFi (таблица, метка, профиль-«рельса»)
# и записывает её в /data/awg/awg.env.
#   awg-detect.sh            если профиль VPN Client один
#   awg-detect.sh wgclt2     если профилей несколько: укажите нужный
# Систему не меняет. В существующем awg.env меняются только TABLE, MARK, PRIO, RAIL_IF (и WANIF, если его не было):
# остальные настройки (MAIN/BACKUP/VPS_IP/…, UI_* от awg-ui-fix) остаются как есть.
# Метка берётся та, которую UniFi реально ставит в UBIOS_PREROUTING_PBR: в UniFi OS 6 схема меток другая
# (0x6a0000/0x7e0000 → 0x21660000/0x3ffe0000), и старое правило ip rule может остаться рядом с новым.
DD=${DD:-/data/awg}
mkdir -p "$DD"
[ -r "$DD/awg.env" ] && . "$DD/awg.env"

# Правило PBR профиля UniFi выглядит так:
#   32504:  from all fwmark 0x6a0000/0x7e0000 lookup 178.wgclt1        (UniFi OS 5)
#   32504:  from all fwmark 0x21660000/0x3ffe0000 lookup 178.wgclt1    (UniFi OS 6)
all=$(ip -4 rule show | awk '
  /fwmark/ && /lookup [0-9]+\.[a-z]+clt[0-9]+/ {
    prio=$1; sub(":","",prio); m=""; t=""
    for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1) }
    split(t,a,"."); print prio, m, a[1], a[2]
  }')
# оставить правила, чью метку ставит UniFi (метка правила с маской совпадает с меткой из цепочки PBR)
used=$(iptables -w 10 -t mangle -S UBIOS_PREROUTING_PBR 2>/dev/null | grep -oE 'set-xmark 0x[0-9a-fA-F]+/0x[0-9a-fA-F]+' | awk '{print $2}' | sort -u)
rules=""
if [ -n "$used" ]; then
  while read -r p m t r; do
    [ -n "$p" ] || continue
    v=${m%%/*}; k=${m#*/}; [ "$k" = "$m" ] && k=0xffffffff
    for u in $used; do
      if [ $(( ${u%%/*} & k )) -eq $(( v )) ]; then rules="$rules$p $m $t $r"$'\n'; break; fi
    done
  done <<< "$all"
fi
[ -n "$rules" ] || rules=$all                     # цепочки нет или ничего не совпало — как раньше
rules=$(printf '%s\n' "$rules" | grep . | awk '!seen[$4]++')   # по одному правилу на профиль
[ "$(printf '%s\n' "$all" | grep -c .)" -gt "$(printf '%s\n' "$rules" | grep -c .)" ] && \
  echo "Пропущены правила со старой меткой (UniFi её больше не ставит): $(printf '%s\n' "$all" | grep . | grep -vxF "$rules" | awk '{print $2}' | tr '\n' ' ')"

if [ -z "$rules" ]; then
  echo "ОШИБКА: правило PBR для VPN Client не найдено."
  echo "Проверьте: профиль VPN Client создан и включён, и на него ссылается"
  echo "хотя бы одно правило Policy-Based Route. Затем запустите скрипт снова."
  exit 1
fi

n=$(echo "$rules" | wc -l)
echo "Найдено PBR-правил VPN Client: $n"
echo "$rules" | awk '{printf "  приоритет %s, метка %s, таблица %s, профиль %s\n",$1,$2,$3,$4}'

if [ -n "$1" ]; then
  line=$(echo "$rules" | awk -v w="$1" '$4==w{print; exit}')
  [ -z "$line" ] && { echo "ОШИБКА: профиль $1 в правилах не найден"; exit 3; }
elif [ "$n" -gt 1 ]; then
  echo "Профилей несколько. Запустите: $0 <профиль>, например: $0 $(echo "$rules" | awk 'NR==1{print $4}')"
  exit 2
else
  line=$rules
fi
read -r PRIO_D MARK_D TABLE_D RAIL_D <<< "$line"

WAN_D=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
case "$WAN_D" in ""|awg*|wg*) WAN_D=eth3 ;; esac

umask 077
if [ -s "$DD/awg.env" ]; then
  # обновить только найденные параметры, остальное в файле не трогать
  set_kv(){
    if grep -q "^$1=" "$DD/awg.env"; then
      awk -v k="$1" -v v="$2" 'index($0, k"=")==1 {print k"="v; next} {print}' "$DD/awg.env" > "$DD/awg.env.t" && mv "$DD/awg.env.t" "$DD/awg.env"
    else printf '%s=%s\n' "$1" "$2" >> "$DD/awg.env"; fi
  }
  old=$MARK
  set_kv TABLE "$TABLE_D"; set_kv MARK "$MARK_D"; set_kv PRIO "$PRIO_D"; set_kv RAIL_IF "$RAIL_D"
  grep -q '^WANIF=' "$DD/awg.env" || set_kv WANIF "$WAN_D"
  [ -n "$old" ] && [ "$old" != "$MARK_D" ] && echo "Метка изменилась: $old → $MARK_D. Примените: systemctl restart awg-failover; rm -f /tmp/awg-self.hash; systemctl restart awg-self 2>/dev/null"
else
cat > "$DD/awg.env" <<ENV
# Параметры AWG failover. После ручной правки: systemctl restart awg-failover
# --- найдено awg-detect.sh (при повторном запуске перезаписывается) ---
TABLE=$TABLE_D
MARK=$MARK_D
PRIO=$PRIO_D
RAIL_IF=$RAIL_D
WANIF=${WANIF:-$WAN_D}
# --- ваши настройки (при повторном запуске сохраняются) ---
MAIN=${MAIN:-awgmain}
BACKUP=${BACKUP-}
VPS_IP=${VPS_IP-}
RECOVER_SEC=${RECOVER_SEC:-600}
EXTRA_SUBNETS="${EXTRA_SUBNETS-}"
ENV
fi
chmod 600 "$DD/awg.env"
echo
echo "Записано в $DD/awg.env:"
grep -E '^(TABLE|MARK|PRIO|RAIL_IF|WANIF|MAIN|BACKUP)=' "$DD/awg.env" | sed 's/^/  /'   # остальное (ключи, токены) не показываем
