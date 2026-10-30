#!/bin/bash
# awg-ui-fix: unifi.ui.com из РФ + собственный трафик роутера через AmneziaWG на UniFi Dream Router 7.
# Ставит /data/awg/self.sh и службу awg-self. Ничего не нужно настраивать руками в интерфейсе UniFi:
#   - домены ui.com dnsmasq резолвит через 9.9.9.9, и этот запрос идёт через AWG (обход geo-DNS-заглушки 451);
#   - связь консоли с облаком Ubiquiti идёт через AWG;
#   - соединения самого роутера следуют Traffic Routes UniFi (правила без Kill Switch), как и LAN.
# Нужно: уже установленный AmneziaWG из /data/awg (awg.env с TABLE и MARK, служба awg-failover).
#
# Запуск с компьютера (R — SSH-алиас роутера):
#   ssh R 'bash -s' < awg-ui-fix.sh                 установить / обновить
#   ssh R 'bash -s -- plan' < awg-ui-fix.sh         показать, что изменит установка (ничего не меняет)
#   ssh R 'bash -s -- check' < awg-ui-fix.sh        только проверка
#   ssh R 'bash -s -- uninstall' < awg-ui-fix.sh    удалить
# Настройки (в /data/awg/awg.env): UI_FIX=yes|no, UI_DOMAINS="ui.com", UI_DNS=9.9.9.9
main(){
DD=/data/awg
act=${1:-install}
die(){ echo "ОШИБКА: $*"; exit 1; }
[ "$(id -u)" = 0 ] || die "нужен root"
[ -r "$DD/awg.env" ] || die "нет $DD/awg.env — сначала установите AmneziaWG"
. "$DD/awg.env"
[ -n "${TABLE:-}" ] && [ -n "${MARK:-}" ] || die "в $DD/awg.env нет TABLE/MARK — запустите $DD/awg-detect.sh"
for b in ipset iptables conntrack ss curl pidof; do command -v $b >/dev/null || die "нет команды $b"; done

case "$act" in
  check)
    [ -x "$DD/self.sh" ] || die "self.sh не установлен"
    systemctl is-active awg-self; "$DD/self.sh" check; exit $?;;
  uninstall)
    systemctl disable --now awg-self 2>/dev/null
    rm -f /etc/systemd/system/awg-self.service; systemctl daemon-reload
    [ -x "$DD/self.sh" ] && "$DD/self.sh" remove
    echo "awg-self удалён: правила убраны, файл dnsmasq удалён, dnsmasq перезапущен. /data/awg/self.sh оставлен."
    exit 0;;
  install|plan) ;;
  *) die "неизвестное действие: $act (install | plan | check | uninstall)";;
esac

systemctl is-active -q awg-failover || echo "ВНИМАНИЕ: awg-failover не запущен — маршрута в туннель (таблица $TABLE) может не быть"
ip -4 route show table "$TABLE" | grep -q '^default dev awg' || echo "ВНИМАНИЕ: в таблице $TABLE нет маршрута через awg — проверьте туннель"

cat > "$DD/self.sh.new" <<'EOF_SELF'
#!/bin/bash
# awg-self: собственный трафик роутера UDR7 через AmneziaWG + рабочий unifi.ui.com из РФ.
#
# 1) Зеркало PBR: соединения самого роутера идут по тем же Traffic Routes UniFi, что и LAN
#    (правила UniFi без Kill Switch, цепочка UBIOS_PREROUTING_PBR).
# 2) UI-модуль (UI_FIX=yes в awg.env) — то, что раньше делалось руками в UniFi:
#    - dnsmasq спрашивает домены UI_DOMAINS (ui.com) у резолвера UI_DNS (9.9.9.9), остальной DNS не трогается;
#    - запросы роутера к UI_DNS идут через AWG (geo-DNS Ubiquiti иначе отдаёт заглушку «Access Prohibited», HTTP 451);
#    - адреса UI_DOMAINS, которые резолвит dnsmasq, попадают в ipset AWG_UI, и соединения консоли с облаком
#      Ubiquiti тоже идут через AWG.
#
#   self.sh run        служба (awg-self.service): каждые 5 с сверяет правила
#   self.sh apply      один проход
#   self.sh reconnect  оборвать текущие соединения роутера к адресам из PBR, чтобы они переподключились через AWG
#   self.sh remove     убрать всё, что ставит эта служба (вкл. файл dnsmasq)
#   self.sh check      проверка: OK / WARN / FAIL
#   self.sh plan       что изменит apply (ничего не меняет)
#   self.sh status     цепочка со счётчиками
DD=${DD:-/data/awg}
iptables(){ command iptables -w 10 "$@"; }   # hotfix: ждать xtables lock, а не падать (иначе ensure плодит копии)
CH=AWG_SELF
UISET=AWG_UI
UIFILE=zz-awg-ui.conf
HASHF=/tmp/awg-self.hash
RESTF=/tmp/awg-self.dnsmasq-restart
PRIV="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4"
# сети Telegram: уведомления роутера сами выбирают путь (awgmain → awgbackup → провайдер), их не метим
TG_NETS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.56.0/22 95.161.64.0/20"

load(){
  TABLE=""; MARK=""; MAIN=awgmain; BACKUP=""; WANIF=ppp0; VPS_IP=""
  UI_FIX=yes; UI_DOMAINS="ui.com"; UI_DNS=9.9.9.9
  [ -r "$DD/awg.env" ] && . "$DD/awg.env"
}
ui_on(){ [ "$UI_FIX" = yes ] && [ -n "$UI_DOMAINS" ] && [ -n "$UI_DNS" ]; }
ensure(){ local t=$1; shift; iptables -t "$t" -C "$@" 2>/dev/null || iptables -t "$t" -A "$@"; }
wanip(){ ip -4 -o addr show dev "$WANIF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
proc_of(){ ss -tnp state established dst "$1" 2>/dev/null | awk 'NR==2{print $NF}' | grep -oE '"[^"]+"' | head -n1; }
log(){ logger -t awg-self "$*" 2>/dev/null; }

# адреса VPS туннелей — их никогда не заворачиваем в туннель
endpoints(){
  { "$DD/awg" show all endpoints 2>/dev/null | awk '{print $3}'; wg show all endpoints 2>/dev/null | awk '{print $3}'; echo "$VPS_IP"; } \
    | sed -E 's/:[0-9]+$//; s/^\[|\]$//g' | grep -E '^[0-9.]+$' | sort -u
}

# адреса, через которые роутер резолвит ВСЁ остальное (dnscrypt-proxy / DoH UniFi и server= в dnsmasq).
# Их никогда не заворачиваем в туннель, даже если IP случайно попал в списки PBR (общие CDN-адреса Cloudflare и т.п.):
# иначе через AWG уйдёт весь DNS роутера. Список запоминается, чтобы не зависеть от момента проверки.
UPF=/tmp/awg-self.upstreams
upstreams(){
  local pid conf
  {
    cat "$UPF" 2>/dev/null
    ss -tunp state established 2>/dev/null | awk '/"dnscrypt-proxy"/{print $5}'
    if pid=$(dnsmasq_pid); then
      conf=$(tr '\0' '\n' < /proc/$pid/cmdline | sed -n 's/^--conf-file=//p')
      grep -hE '^server=[0-9]' "$conf" "$(conf_dir "$pid")"/* 2>/dev/null | grep -v "$UIFILE" | cut -d= -f2 | cut -d'#' -f1 | cut -d@ -f1
    fi
  } | sed -E 's/^\[::ffff://; s/\]?:[0-9]+$//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | grep -v -E '^(127\.|10\.|192\.168\.|0\.)' | grep -v -x -F "${UI_DNS:-none}" | sort -u > "$UPF.tmp"
  mv -f "$UPF.tmp" "$UPF"; cat "$UPF"
}
unstick(){  # перевести текущие соединения роутера к адресу обратно на WAN (они могли уйти в AWG до исключения)
  local wip; wip=$(wanip)
  [ -n "$wip" ] && conntrack -L -s "$wip" -d "$1" 2>/dev/null | grep -q 'dst=10\.8\.1\.' || return 0
  ss -K dst "$1" >/dev/null 2>&1; conntrack -D -s "$wip" -d "$1" >/dev/null 2>&1
  log "DNS-апстрим $1 возвращён на $WANIF"
}

# правила маркировки UniFi PBR без условия «источник = локальная сеть»
want(){
  iptables -t mangle -S UBIOS_PREROUTING_PBR 2>/dev/null | grep -- ' -j MARK ' \
    | sed -E -e 's/^-A UBIOS_PREROUTING_PBR //' \
             -e 's/-m set --match-set UBIOS_local_network(v6)? src //' \
             -e 's/-m comment --comment [^ ]+ //' \
    | grep -v -E -- '--mac-source|(^| )-i |--match-set [^ ]+ src|(^| )-s '
}

hook(){  # переход в нашу цепочку должен быть ПЕРВЫМ в mangle OUTPUT (до UBIOS_OUTPUT_JUMP)
  [ "$(iptables -t mangle -S OUTPUT | grep '^-A OUTPUT' | head -n1)" = "-A OUTPUT -j $CH" ] && return
  while iptables -t mangle -D OUTPUT -j $CH 2>/dev/null; do :; done
  iptables -t mangle -I OUTPUT 1 -j $CH
}

mss(){  # MSS для соединений самого роутера через туннель
  local i m
  for i in $MAIN $BACKUP; do
    m=$(cat /sys/class/net/$i/mtu 2>/dev/null) || continue
    ensure mangle POSTROUTING -o "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ensure mangle PREROUTING  -i "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $((m-40))
  done
  mss_dups | while read -r n r; do   # копии одного правила (остались от гонок старых версий) — оставить одну
    while [ "$n" -gt 1 ]; do iptables -t mangle -D ${r#-A } || break; n=$((n-1)); done
  done
}
mss_dups(){  # «число строка» для правил TCPMSS на awg*, которые стоят в mangle больше одного раза
  local c
  for c in POSTROUTING PREROUTING; do
    iptables -t mangle -S "$c" 2>/dev/null | grep -E -- '-[io] awg[^ ]* .*-j TCPMSS' | sort | uniq -c | awk '$1>1'
  done
}

# ---------- dnsmasq (UI-модуль) ----------
dnsmasq_pid(){  # основной dnsmasq UniFi (тот, что с --conf-dir: DNS + DHCP для LAN)
  local p
  p=$(cat /run/dnsmasq-main.pid 2>/dev/null)
  if [ -n "$p" ] && [ -d "/proc/$p" ]; then echo "$p"; return 0; fi
  for p in $(pidof dnsmasq); do
    tr '\0' '\n' < /proc/$p/cmdline 2>/dev/null | grep -q -- '^--conf-dir=' && { echo "$p"; return 0; }
  done
  return 1
}
conf_dir(){ tr '\0' '\n' < /proc/$1/cmdline 2>/dev/null | sed -n 's/^--conf-dir=//p' | cut -d, -f1 | head -n1; }
pstart(){  # время старта процесса, epoch
  local st bt hz
  st=$(awk '{print $22}' /proc/$1/stat 2>/dev/null); bt=$(awk '/^btime/{print $2}' /proc/stat); hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  [ -n "$st" ] && echo $(( bt + st / hz ))
}
ui_conf(){  # $1 — pid основного dnsmasq
  local d s files
  files=$(dnsmasq_files "$1")
  echo "# awg-self: домены UniFi резолвятся через $UI_DNS (через AWG). Файл создаёт /data/awg/self.sh, не редактировать."
  for d in $UI_DOMAINS; do
    s=$(uni_sets "$d" "$files")
    echo "server=/$d/$UI_DNS"; echo "ipset=/$d/$UISET${s:+,$s}"
  done
}
dnsmasq_files(){  # конфиги основного dnsmasq, кроме нашего файла
  local dir f; dir=$(conf_dir "$1")
  { tr '\0' '\n' < /proc/$1/cmdline 2>/dev/null | sed -n 's/^--conf-file=//p'
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      for f in "$dir"/*; do [ -f "$f" ] && [ "${f##*/}" != "$UIFILE" ] && echo "$f"; done
    fi; } | grep -v '^$'
}
# Наборы ipset, в которые dnsmasq без нас положил бы адреса домена $1 (правила Traffic Routes UniFi).
# dnsmasq берёт для имени ОДНУ строку ipset= (самый длинный совпавший домен). Если UniFi PBR и UI_DOMAINS
# содержат один домен (например youtube.com), без объединения работала бы только одна из строк, и доменное
# правило UniFi оставалось бы пустым. Поэтому наша строка повторяет наборы UniFi: ipset=/d/AWG_UI,<наборы UniFi>.
uni_sets(){
  local d=$1 files=$2
  [ -n "$files" ] || return 0
  # shellcheck disable=SC2086
  grep -h '^ipset=/' $files 2>/dev/null | awk -F/ -v d="$(echo "$d" | tr 'A-Z' 'a-z')" -v own="$UISET" '
    { sets=$NF; gsub(/[ \t\r]+$/, "", sets)
      for (i = 2; i < NF; i++) {
        x = tolower($i); if (x == "") continue
        if (d == x || (length(d) > length(x) && substr(d, length(d) - length(x)) == "." x)) {
          if (length(x) > best) { best = length(x); n = 0 }
          if (length(x) == best) list[++n] = sets
        }
      } }
    END {
      out = ""
      for (k = 1; k <= n; k++) {
        m = split(list[k], a, ",")
        for (j = 1; j <= m; j++) if (a[j] != "" && a[j] != own && !(a[j] in seen)) { seen[a[j]] = 1; out = out "," a[j] }
      }
      print substr(out, 2)
    }'
}
restart_dnsmasq(){  # UniFi сам перезапускает dnsmasq; если нет — запускаем той же командой
  local pid=$1 cmd i np
  local last; last=$(cat $RESTF 2>/dev/null || echo 0)
  [ $(( $(date +%s) - last )) -lt 60 ] && return 0          # не чаще раза в минуту
  date +%s > $RESTF
  cmd=$(tr '\0' ' ' < /proc/$pid/cmdline)
  log "перезапуск dnsmasq ($pid), чтобы подхватить $UIFILE"
  kill "$pid" 2>/dev/null
  for i in $(seq 1 15); do
    sleep 1; np=$(dnsmasq_pid) && [ "$np" != "$pid" ] && return 0
  done
  log "UniFi не поднял dnsmasq за 15 с — запускаю сам: $cmd"
  setsid $cmd </dev/null >/dev/null 2>&1 9>&- &
  sleep 2
}
ui_dns(){  # держит файл в conf-dir dnsmasq и следит, что dnsmasq его загрузил
  local pid dir f st mt c
  pid=$(dnsmasq_pid) || { log "не найден dnsmasq с --conf-dir — UI-модуль пропущен"; return 0; }
  dir=$(conf_dir "$pid"); [ -d "$dir" ] || return 0
  f="$dir/$UIFILE"
  if ! ui_on; then
    [ -f "$f" ] && { rm -f "$f"; restart_dnsmasq "$pid"; }
    return 0
  fi
  c=$(ui_conf "$pid")
  [ "$(cat "$f" 2>/dev/null)" = "$c" ] || printf '%s\n' "$c" > "$f"
  st=$(pstart "$pid"); mt=$(stat -c %Y "$f")
  [ -n "$st" ] && [ "$st" -lt "$mt" ] && restart_dnsmasq "$pid"   # dnsmasq старше файла → не видел его
  return 0
}

build(){  # собрать цепочку целиком в ${CH}_NEW и подменить: рабочая цепочка ни на миг не бывает пустой
  local w=$1 ep=$2 up=$3 T=${CH}_NEW O=${CH}_OLD n r
  while iptables -t mangle -D OUTPUT -j $O 2>/dev/null; do :; done
  iptables -t mangle -F $O 2>/dev/null; iptables -t mangle -X $O 2>/dev/null
  iptables -t mangle -N $T 2>/dev/null; iptables -t mangle -F $T
  iptables -t mangle -A $T -m mark ! --mark 0x0/0x7e0000 -j RETURN
  for n in $PRIV $TG_NETS $ep $up; do iptables -t mangle -A $T -d "$n" -j RETURN; done
  if ui_on; then
    iptables -t mangle -A $T -d "$UI_DNS" -j MARK --set-xmark "$MARK"
    iptables -t mangle -A $T -d "$UI_DNS" -j RETURN
    iptables -t mangle -A $T -m set --match-set $UISET dst -j MARK --set-xmark "$MARK"
    iptables -t mangle -A $T -m set --match-set $UISET dst -j RETURN
  fi
  while read -r r; do  # как у UniFi: первое совпадение ставит метку и выходит
    [ -n "$r" ] || continue
    iptables -t mangle -A $T $r && iptables -t mangle -A $T ${r% -j MARK*} -j RETURN
  done <<< "$w"
  iptables -t mangle -S $CH >/dev/null 2>&1 && iptables -t mangle -E $CH $O
  iptables -t mangle -E $T $CH
  hook                                                   # переход на новую цепочку — первым
  while iptables -t mangle -D OUTPUT -j $O 2>/dev/null; do :; done
  iptables -t mangle -F $O 2>/dev/null; iptables -t mangle -X $O 2>/dev/null
}

apply(){  # один проход за раз (служба, ручной apply, установщик); блокировка снимается по выходу из подоболочки
  if command -v flock >/dev/null; then ( flock -w 30 9 || exit 0; apply_body ) 9>/run/awg-self.lock; else apply_body; fi
  return 0
}

apply_body(){
  load
  [ -n "$TABLE" ] && [ -n "$MARK" ] || { echo "нет TABLE/MARK в awg.env"; return 0; }
  local w ep up h ip
  w=$(want); ep=$(endpoints); up=$(upstreams)
  ui_on && ipset create $UISET hash:ip family inet -exist
  h=$(printf 'v9\n%s\n%s\n%s\n%s %s %s\n' "$w" "$ep" "$up" "$UI_FIX" "$UI_DNS" "$UI_DOMAINS" | md5sum | cut -c1-12)
  if [ "$(cat $HASHF 2>/dev/null)" != "$h" ] || ! iptables -t mangle -S $CH >/dev/null 2>&1; then
    build "$w" "$ep" "$up"
    echo "$h" > $HASHF
    for ip in $up; do unstick "$ip"; done
  fi
  legacy
  hook
  mss
  ui_dns
  return 0
}

legacy(){  # убрать «весь DNS роутера через AWG» из промежуточной версии
  iptables -t mangle -S AWG_SELF_DNS >/dev/null 2>&1 || return 0
  local ip wip; wip=$(wanip)
  iptables -t mangle -F AWG_SELF_DNS; iptables -t mangle -X AWG_SELF_DNS 2>/dev/null
  for ip in $(cut -s -d' ' -f2- /tmp/awg-self.dns 2>/dev/null); do
    ss -K dst "$ip" >/dev/null 2>&1; [ -n "$wip" ] && conntrack -D -s "$wip" -d "$ip" >/dev/null 2>&1
  done
  rm -f /tmp/awg-self.dns /tmp/awg-self.dnsips
}

# ---------- проверки ----------
inset(){  # адрес в наборе? (UBIOS_* — list:set, проверяем участников)
  local s=$1 d=$2 m
  if ipset list -t "$s" 2>/dev/null | grep -q 'Type: list:set'; then
    for m in $(ipset list "$s" 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2); do
      ipset test "$m" "$d" >/dev/null 2>&1 && return 0
    done
    return 1
  fi
  ipset test "$s" "$d" >/dev/null 2>&1
}
chain_sets(){ iptables -t mangle -S $CH 2>/dev/null | awk '/-j MARK/{for(i=1;i<=NF;i++) if($i=="--match-set") print $(i+1)}' | sort -u; }
in_pbr(){  # уйдёт ли соединение роутера к адресу в AWG
  local s
  iptables -t mangle -S $CH 2>/dev/null | grep -q -- "-d $1/32 -j MARK" && return 0
  iptables -t mangle -S $CH 2>/dev/null | grep -q -- "-d $1/32 -j RETURN" && return 1   # исключён (VPS, DNS роутера)
  for s in $(chain_sets); do inset "$s" "$1" && return 0; done
  return 1
}

plan(){  # что изменит apply: копии правил TCPMSS и файл dnsmasq. Ничего не меняет.
  load
  local pid dir f new d
  echo "== копии правил TCPMSS (apply оставит по одному) =="
  d=$(mss_dups); if [ -n "$d" ]; then echo "$d" | sed -E 's/^ *([0-9]+) /  ×\1  /'; else echo "  нет"; fi
  echo "== файл dnsmasq $UIFILE =="
  ui_on || { echo "  UI-модуль выключен (UI_FIX=$UI_FIX)"; return 0; }
  pid=$(dnsmasq_pid) || { echo "  основной dnsmasq не найден"; return 0; }
  dir=$(conf_dir "$pid"); f="$dir/$UIFILE"; new=$(ui_conf "$pid")
  if [ "$(cat "$f" 2>/dev/null)" = "$new" ]; then echo "  без изменений"
  else
    diff <(cat "$f" 2>/dev/null) <(printf '%s\n' "$new") | grep '^[<>]' | sed 's/^< /  было:   /; s/^> /  станет: /'
    echo "  (после установки dnsmasq перезапустится один раз: DNS прервётся на 1–2 с)"
  fi
}

reconnect(){
  load
  local wip d n=0
  wip=$(wanip)
  [ -n "$wip" ] || { echo "не найден адрес на $WANIF"; return 1; }
  for d in $(conntrack -L -s "$wip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^dst=/){print substr($i,5); break}}' | sort -u); do
    iptables -t mangle -C $CH -d "$d" -j RETURN 2>/dev/null && ! iptables -t mangle -C $CH -d "$d" -j MARK --set-xmark "$MARK" 2>/dev/null && continue
    conntrack -L -s "$wip" -d "$d" 2>/dev/null | grep -q 'dst=10\.8\.1\.' && continue   # уже через AWG
    if in_pbr "$d" && ip route get "$d" mark "${MARK%/*}" 2>/dev/null | grep -q 'dev awg'; then
      ss -K dst "$d" >/dev/null 2>&1
      conntrack -D -s "$wip" -d "$d" >/dev/null 2>&1
      echo "переподключение: $d"; n=$((n+1))
    fi
  done
  echo "оборвано направлений: $n"
}

remove(){
  load
  local i m pid dir
  for c in $CH ${CH}_OLD ${CH}_NEW; do
    while iptables -t mangle -D OUTPUT -j $c 2>/dev/null; do :; done
    iptables -t mangle -F $c 2>/dev/null; iptables -t mangle -X $c 2>/dev/null
  done
  for i in $MAIN $BACKUP; do
    iptables -t mangle -D POSTROUTING -o "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    m=$(cat /sys/class/net/$i/mtu 2>/dev/null) && iptables -t mangle -D PREROUTING -i "$i" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $((m-40)) 2>/dev/null
  done
  legacy
  if pid=$(dnsmasq_pid); then
    dir=$(conf_dir "$pid")
    if [ -f "$dir/$UIFILE" ]; then rm -f "$dir/$UIFILE"; rm -f $RESTF; restart_dnsmasq "$pid"; fi
  fi
  ipset destroy $UISET 2>/dev/null
  rm -f $HASHF $UPF
}

check(){
  load
  local rc=0 n wip ok d c fw ips code pid dir st mt up
  if [ "$(iptables -t mangle -S OUTPUT | grep '^-A OUTPUT' | head -n1)" = "-A OUTPUT -j $CH" ]; then echo "OK     цепочка $CH стоит первой в mangle OUTPUT"
  else echo "FAIL   переход в $CH не первый в mangle OUTPUT (служба awg-self запущена?)"; rc=1; fi
  n=$(pgrep -fc 'self\.sh run' 2>/dev/null || echo 0)
  [ "$n" -gt 1 ] && { echo "WARN   запущено $n копий «self.sh run» — должна быть одна (служба awg-self): $(pgrep -f 'self\.sh run' | tr '\n' ' ')"; }
  [ "$(iptables -t mangle -S $CH 2>/dev/null | grep -c -- ' -j MARK ')" -gt "$(( $(want | grep -c .) + 2 ))" ] && echo "WARN   в $CH есть дубли правил (выполните apply)"
  n=$(mss_dups | grep -c .); [ "$n" -gt 0 ] && echo "WARN   правил TCPMSS для awg* с копиями: $n (служба уберёт копии за 5 с; если не уходят — $DD/self.sh apply)"
  n=$(want | grep -c .)
  echo "INFO   правил PBR UniFi (без Kill Switch), повторённых для роутера: $n"
  iptables -t mangle -S AWG_SELF_DNS >/dev/null 2>&1 && echo "WARN   осталась цепочка AWG_SELF_DNS от старой версии (выполните apply)"
  echo "INFO   таблица $TABLE: $(ip route show table "$TABLE" | head -n1)"
  local u ubad=""; wip=$(wanip)
  for u in $(cat $UPF 2>/dev/null); do conntrack -L -s "$wip" -d "$u" 2>/dev/null | grep -q 'dst=10\.8\.1\.' && ubad="$ubad $u"; done
  if [ -n "$ubad" ]; then echo "FAIL   общий DNS роутера идёт через AWG:$ubad (должен идти через $WANIF)"; rc=1
  else echo "OK     общий DNS роутера ($(cat $UPF 2>/dev/null | tr '\n' ' '| sed 's/ $//')) идёт мимо туннеля, через $WANIF"; fi

  if ui_on; then
    pid=$(dnsmasq_pid); dir=$(conf_dir "$pid")
    if [ -f "$dir/$UIFILE" ]; then
      st=$(pstart "$pid"); mt=$(stat -c %Y "$dir/$UIFILE")
      if [ "$st" -ge "$mt" ]; then echo "OK     dnsmasq загрузил $dir/$UIFILE: $UI_DOMAINS → $UI_DNS"
      else echo "FAIL   dnsmasq запущен раньше, чем появился $UIFILE (служба перезапустит его в течение минуты)"; rc=1; fi
      [ "$(cat "$dir/$UIFILE" 2>/dev/null)" = "$(ui_conf "$pid")" ] || echo "WARN   $UIFILE не совпадает с текущими правилами PBR UniFi (служба обновит его за 5 с)"
      c=$(grep '^ipset=' "$dir/$UIFILE" 2>/dev/null | grep -F "/$UISET," | cut -d/ -f2 | tr '\n' ' ')
      [ -n "$c" ] && echo "INFO   домены, общие с правилами PBR UniFi (адреса идут и в $UISET, и в наборы UniFi): $c"
    else echo "FAIL   нет $dir/$UIFILE (служба awg-self запущена?)"; rc=1; fi
    up=$(grep -rhE '^server=[0-9]' "$(dirname "$(tr '\0' '\n' < /proc/$pid/cmdline | sed -n 's/^--conf-file=//p')")" "$dir" 2>/dev/null | cut -d= -f2 | cut -d'#' -f1 | sort -u | tr '\n' ' ')
    echo " $up " | grep -q " $UI_DNS " && { echo "FAIL   $UI_DNS — это общий DNS роутера: через туннель уйдёт весь DNS. Задайте другой UI_DNS"; rc=1; }
    if in_pbr "$UI_DNS"; then echo "OK     запросы к $UI_DNS идут через AWG ($(ip route get "$UI_DNS" mark "${MARK%/*}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'))"
    else echo "FAIL   запросы к $UI_DNS не маркируются"; rc=1; fi
    echo "INFO   адресов облака в $UISET: $(ipset list $UISET 2>/dev/null | sed -n '/^Members:/,$p' | tail -n +2 | grep -c .)"
  else
    echo "INFO   UI-модуль выключен (UI_FIX=$UI_FIX)"
    fw=$(grep -rhoE 'server=/([a-z0-9.-]*/)*ui\.com/[^/]*/?[0-9.]+' /run/dnsmasq.dns.conf.d /run/dnsmasq.dhcp.conf.d 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    [ -n "$fw" ] && echo "INFO   есть Forward Domain ui.com из UniFi → $fw"
  fi

  ips=$(getent ahostsv4 unifi.ui.com 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [ -z "$ips" ]; then echo "FAIL   unifi.ui.com не резолвится"; rc=1
  else  # заглушка определяется по ответу (451), а не по списку адресов: Ubiquiti меняет её IP
    local bad="" ip c2
    for ip in $ips; do
      c2=$(curl -s -o /dev/null -m 8 --resolve "unifi.ui.com:443:$ip" -w '%{http_code}' https://unifi.ui.com/ 2>/dev/null)
      [ "$c2" = 451 ] && bad="$bad $ip"
    done
    if [ -n "$bad" ]; then echo "FAIL   unifi.ui.com →$bad — заглушка 451 (geo-DNS); кэш? killall -HUP dnsmasq"; rc=1
    else echo "OK     unifi.ui.com → $ips(не заглушка)"; fi
  fi

  wip=$(wanip)
  ok=$(conntrack -L -s "$wip" 2>/dev/null | grep -c 'dst=10\.8\.1\.')
  echo "INFO   соединений роутера через AWG сейчас: $ok"
  for d in $(ss -tn state established 2>/dev/null | awk 'NR>1{print $4}' | sed -E 's/^\[::ffff://; s/\]?:[0-9]+$//' | grep -E '^[0-9.]+$' | grep -v -E '^(192\.168|127\.|10\.)' | sort -u); do
    c=$(conntrack -L -s "$wip" -d "$d" 2>/dev/null | head -n1)
    if echo "$c" | grep -q 'dst=10\.8\.1\.'; then echo "OK     $d → через AWG ($(proc_of "$d"))"
    elif [ -n "$c" ]; then
      if grep -qxF "$d" "$UPF" 2>/dev/null; then echo "INFO   $d → DNS роутера, напрямую через $WANIF ($(proc_of "$d")) — так и задумано"
      elif in_pbr "$d"; then echo "WARN   $d → должно идти через AWG, но идёт напрямую через $WANIF ($(proc_of "$d")): старое соединение, нужен reconnect"
      else echo "INFO   $d → не в списках, напрямую через $WANIF ($(proc_of "$d")) — так и задумано"; fi
    fi
  done
  return $rc
}

case "${1:-run}" in
  run)       trap 'exit 0' TERM INT; while :; do apply; sleep 5 & wait $!; done;;
  apply)     apply;;
  reconnect) reconnect;;
  remove)    remove;;
  check)     check;;
  plan)      plan;;
  status)    iptables -t mangle -L $CH -v -n --line-numbers; iptables -t mangle -S OUTPUT; ipset list $UISET 2>/dev/null | head -20;;
  *)         echo "использование: $0 [run|apply|reconnect|remove|check|plan|status]"; exit 1;;
esac
EOF_SELF
chmod +x "$DD/self.sh.new"
if [ "$act" = plan ]; then
  "$DD/self.sh.new" plan; rm -f "$DD/self.sh.new"
  echo; echo "Ничего не изменено. Установить: ssh R 'bash -s' < awg-ui-fix.sh"
  exit 0
fi
mv -f "$DD/self.sh.new" "$DD/self.sh"

cat > "$DD/awg-self.service" <<'EOF_UNIT'
[Unit]
Description=AWG: own router traffic follows UniFi PBR into the tunnel; unifi.ui.com via AWG DNS
After=awg-failover.service network-online.target

[Service]
ExecStart=/data/awg/self.sh run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_UNIT

if ! grep -q '^UI_FIX=' "$DD/awg.env"; then
  cat >> "$DD/awg.env" <<'EOF_ENV'
# --- awg-self: unifi.ui.com через туннель (UI_FIX=no — выключить) ---
UI_FIX=yes
UI_DOMAINS="ui.com"
UI_DNS=9.9.9.9
EOF_ENV
  echo "в awg.env добавлены UI_FIX / UI_DOMAINS / UI_DNS"
fi

cp "$DD/awg-self.service" /etc/systemd/system/awg-self.service
systemctl daemon-reload
systemctl enable awg-self >/dev/null 2>&1
systemctl restart awg-self
echo "awg-self запущен, жду применения правил и перезапуска dnsmasq…"
sleep 15
"$DD/self.sh" reconnect
sleep 5
echo; "$DD/self.sh" check
echo
echo "Если в UniFi вручную создан Forward Domain ui.com или PBR для 9.9.9.9 — их можно удалить: служба делает то же самое сама."
}
main "$@" </dev/null
