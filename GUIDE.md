# AmneziaWG на UDR7

*Полевой мануал · UniFi Dream Router 7*

Туннель AmneziaWG прямо на роутере, встроенный в штатные правила Policy-Based Routes UniFi. В туннель уходят только те устройства и сайты, которые вы выбрали в интерфейсе UniFi. Дальше по желанию: запасной канал на своём VPS с автопереключением, панель состояния при входе по SSH, аудит и уведомления в Telegram. Всё ставится одной командой через установщик или вручную по шагам ниже.

> [!TIP]
> Короткий путь — установщик одной командой, см. [«Установщик одной командой»](#auto). Части 0–13 — те же шаги вручную, для понимания и диагностики. Интерактивная версия с выбором сценария: `index.html` (GitHub Pages).

## Содержание

- [Установщик одной командой](#auto)
- [Как это устроено](#how)
- [0. Подготовка](#p0)
- [1. Бинарники AmneziaWG на роутер](#p1)
- [2. Профиль-«рельса» и правила PBR](#p2)
- [3. Свой сервер AmneziaWG на VPS](#p3)
- [4. Основной туннель awgmain](#p4)
- [5. Сторож и автозапуск](#p5)
- [6. Запасной канал и автопереключение](#p6)
- [7. Клиенты VPN-сервера роутера через туннель](#p7)
- [8. Панель состояния при входе по SSH](#p8)
- [9. Аудит установки](#p9)
- [10. Уведомления в Telegram](#p10)
- [11. Обслуживание](#p11)
- [12. Диагностика и проблемы](#p12)
- [13. Справочник](#p13)


## Выберите свой сценарий

Роутер у всех один и тот же, а задачи разные. Скрипты одинаковые для всех сценариев, различаются только настройки в файле awg.env.

| Сценарий                           | Что у вас есть                                                            | Части гайда      |
|------------------------------------|---------------------------------------------------------------------------|------------------|
| **A** · один туннель от провайдера | Готовый конфиг AmneziaWG (.conf) от VPN-сервиса или из приложения Amnezia | 0, 1, 2, 4, 5    |
| **B** · один туннель до своего VPS | Арендованный сервер с Ubuntu, сервер AWG поднимаете сами                  | 0, 1, 2, 3, 4, 5 |
| **C** · основной + запасной        | Конфиг провайдера и свой VPS; автопереключение и возврат через 10 минут   | 0–6              |
| \+ клиенты VPN-сервера роутера     | Через туннель ходят и клиенты Teleport / WireGuard Server                 | \+ 7             |
| По желанию                         | Панель, аудит, Telegram, обслуживание                                     | 8, 9, 10, 11     |

<a name="auto"></a>

## Установщик одной командой

Установщик `install.sh` делает всё, что описано в частях 0–11: проверяет роутер, ставит бинарники, принимает конфиг, поднимает и проверяет туннели, сам настраивает ваш VPS по SSH, находит таблицу и метку PBR, запускает сторожа и по желанию ставит панель, аудит и Telegram. На каждом шаге он проверяет результат и при ошибке предлагает варианты: повторить, заменить конфиг, запустить диагностику.

**Роутер** · первый запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lexer86/AmneziaWG3.1-UDR7/main/install.sh)
```

| Мастер спросит                                               | Что проверит                                                                                                   |
|--------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| Сценарий A, B или C                                          | aarch64, UniFi OS, `/dev/net/tun`, место на `/data`, доступ к GitHub, остатки старых установок                 |
| Откуда взять бинарники                                       | что они запускаются на роутере                                                                                 |
| Конфиг основного туннеля (вставить текстом или путь к файлу) | секции, ключи, Address, Endpoint; предупредит, если это обычный WireGuard                                      |
| Для своего VPS: IP, SSH-порт, порт AWG, параметры обфускации | SSH и root, ОС; соберёт и настроит сервер, заберёт конфиг; при сбое — tcpdump одновременно на роутере и на VPS |
| Какой профиль VPN Client использовать как рельсу             | есть ли правило PBR; если нет — создаст фиктивный конфиг и покажет шаги в UniFi                                |
| Подсети VPN-сервера роутера, время возврата                  | что сторож положил маршрут и `blackhole` в таблицу PBR; переключение на запасной канал                         |
| Панель, аудит, Telegram                                      | токен бота, chat id (определит сам), доставку тестового сообщения                                              |

**Роутер** · после установки

```bash
/data/awg/install.sh            # меню: обновление, компоненты, диагностика, удаление
/data/awg/install.sh --update   # обновить скрипты, конфиги сохраняются
/data/awg/install.sh --restore  # после обновления прошивки UniFi
/data/awg/install.sh --uninstall
```

Части ниже — те же шаги вручную. Они нужны, чтобы понимать, что делает установщик, и для диагностики, если что-то пошло не так.

<a name="how"></a>

## Как это устроено

Главная хитрость в том, что UniFi сам умеет выбирать, какой трафик пускать в VPN, но не умеет AmneziaWG. Поэтому мы разделяем работу: **UniFi решает, что направить в туннель, а наш туннель решает, как это доставить.**

    Устройство под правилом PBR
      → UniFi ставит метку fwmark, ip rule отправляет пакет в таблицу профиля VPN Client
      → таблица PBR (у нас 178):
           default dev awgmain    metric 5     ← активный туннель (кладёт сторож)
           default dev awgbackup               ← при сбое основного
           default dev wgclt1     metric 37    ← «рельса» UniFi
           blackhole default      metric 200   ← туннели лежат: стоп, а не утечка в WAN

- **Туннель AmneziaWG** поднимает userspace-демон `amneziawg-go`. Модуля AWG в ядре UDR7 нет, а `/dev/net/tun` есть.
- **«Рельса».** Профиль VPN Client в UniFi нужен только ради метки и таблицы PBR. Его собственный туннель не используется и может даже не подниматься.
- **Сторож** (`failover.sh`) каждые 5 секунд кладёт в эту таблицу маршрут на живой AWG-туннель с метрикой 5. Она меньше, чем у маршрута UniFi, поэтому выбирается наш.
- **Блокировка вместо утечки.** Маршрут `blackhole` с метрикой 200 гарантирует: если туннели лежат, PBR-трафик остановится, а не уйдёт напрямую через провайдера.
- **Остальной трафик не трогаем.** Всё, что не попало под PBR, идёт как обычно через WAN.
- **Всё хранится в `/data/awg`.** Этот раздел переживает обновления прошивки, а автозапуск восстанавливается одной командой.

> [!NOTE]
> **Почему не обычный WireGuard**
>
> Это первый урок из реальной установки. Обычный WireGuard до своего сервера поднимался, проходил handshake, отдавал 4–5 пингов и через 5–8 секунд замолкал в обе стороны. Обычный UDP на тот же сервер и порт жил без обрывов (40 из 40 пакетов), смена порта не помогала. Так ведёт себя DPI, который распознаёт WireGuard и рубит поток. AmneziaWG маскирует handshake и размеры пакетов, и с ним тот же сервер работал стабильно. Как проверить это у себя, описано в части [12 «Диагностика и проблемы»](#p12).

> [!NOTE]
> **Что проверено вживую, а что нет**
>
> **Вживую** на UDR7 работает вся схема: основной туннель от провайдера по протоколу AmneziaWG 3.1 (параметры `S3`, `S4`, `I1`, `HeaderProtectionKey`), запасной до своего VPS, PBR по доменам и адресам, клиенты VPN-сервера роутера через ipset, переключение и возврат, панель, аудит, уведомления.
>
> **На заглушках** проверены универсальные версии скриптов из этого гайда: автоопределение таблицы и метки (`awg-detect.sh`), файл `awg.env`, режим одного туннеля, фиктивный профиль-«рельса», установка сервера одним скриптом, удаление и восстановление. Логика у них та же, что в рабочей установке, но на чужом роутере они ещё не запускались. Поэтому каждый шаг заканчивается проверкой.

<a name="p0"></a>

## 0. Подготовка

### Что понадобится

| Что                                                        | Зачем                                        | Сценарий   |
|------------------------------------------------------------|----------------------------------------------|------------|
| UDR7 с доступом по SSH (root)                              | Установка                                    | все        |
| Конфиг AmneziaWG `.conf` со строкой `Address`              | Основной туннель                             | A, C       |
| VPS: Ubuntu 22.04/24.04 x86_64, публичный IPv4, root       | Свой сервер AWG                              | B, C       |
| Два тестовых устройства: одно под правилом PBR, другое нет | Проверка, что в туннель уходит только нужное | все        |
| Бот Telegram                                               | Уведомления                                  | по желанию |

Белый IP роутеру не нужен: AmneziaWG-клиент только подключается наружу и работает за NAT провайдера (CGNAT). Белый IP нужен серверу, к которому подключаетесь.

### Правила безопасности

> [!CAUTION]
> **Важнее удобства**
>
> - **Один конфиг = одно устройство.** Если один ключ работает на двух клиентах сразу (например, роутер и старый контейнер), сервер будет перекидывать endpoint между ними, и оба канала станут нестабильными. Для роутера запросите у провайдера отдельный конфиг.
> - **Ключи и токены не вставляются в чаты, тикеты и скриншоты.** Всё, что туда попало, считается скомпрометированным: ключ перевыпускается, токен бота отзывается в @BotFather.
> - Файлы с ключами получают права `600`. Все команды гайда создают их так.
> - Перед вставкой команды смотрите на приглашение терминала: `root@UDR7` или `root@ваш-vps`. Скрипты сервера сами отказываются работать на роутере, но лучше не ошибаться.

### Как читать блоки команд

У каждого блока есть метка, где его выполнять, и кнопка «Копировать». Большие блоки вида `cat > файл <<'EOF' … EOF` вставляйте целиком, одним куском: они создают файл.

| Метка      | Где                                                                   |
|------------|-----------------------------------------------------------------------|
| **Роутер** | SSH на UDR7 под root                                                  |
| **VPS**    | SSH на ваш сервер под root                                            |
| **ПК**     | Терминал вашего компьютера (PowerShell в Windows 10/11 тоже подойдёт) |
| **UniFi**  | Веб-интерфейс UniFi Network                                           |

### 0.1 Включите SSH и подключитесь

В веб-интерфейсе UniFi включите SSH для консоли и задайте пароль root. Пункт находится в настройках консоли UniFi OS (Control Plane → Console, раздел SSH); точное название зависит от версии.

**ПК** · подключение

```bash
ssh root@192.168.1.1
```

### 0.2 Проверьте платформу

**Роутер** · только чтение

```bash
uname -m; uname -r
ls -l /dev/net/tun
df -h /data | tail -1
command -v curl python3 tcpdump iptables ipset
```

*Вывод — ожидаемо*

```text
aarch64
5.4.213-ui-ipq5322-wireless
crw-rw-rw- 1 root root 10, 200 ... /dev/net/tun
/dev/...   ...  ...  ...  ..% /data
/usr/bin/curl
/usr/bin/python3
...
```

> [!TIP]
> **Проверка**
>
> Архитектура `aarch64`, устройство `/dev/net/tun` существует, на `/data` есть хотя бы 50 МБ свободного места. Без `/dev/net/tun` userspace-туннель не создать, дальше идти нет смысла.

<a name="p1"></a>

## 1. Бинарники AmneziaWG на роутер

Нужны два файла под aarch64: демон `amneziawg-go` (создаёт интерфейс туннеля) и утилита `awg` (настраивает его, аналог `wg`). Готовые сборки есть в архиве проекта [AmneziaWG-Unifi-DreamMachine](https://github.com/DjGreeZ/AmneziaWG-Unifi-DreamMachine). Из него мы берём только бинарники.

> [!CAUTION]
> **Не запускайте install.sh этого проекта на UDR7**
>
> Установщик патчит JS-файлы веб-интерфейса UniFi и сверяет их контрольные суммы. На UDR7 с Network 10.6.106 он упал с `FileNotFoundError: …/react/js/94924.….js`: имена файлов меняются от сборки к сборке. Дорабатывать его не нужно, интерфейс UniFi в нашей схеме не меняется. Если вы уже запускали установщик, проверьте, что он ничего не оставил: `ls /data/awg-native` (каталога быть не должно).

### 1.1 Скачайте архив и достаньте бинарники

**Роутер** · скачать и установить в /data/awg

```bash
mkdir -p /data/awg && cd /tmp
curl -fL https://github.com/DjGreeZ/AmneziaWG-Unifi-DreamMachine/raw/main/AmneziaWG-UniFi-v0.2.1-source.tar.gz -o awg-src.tar.gz
mkdir -p awgx && tar xzf awg-src.tar.gz -C awgx
ls -l awgx/bin
cp awgx/bin/amneziawg-go awgx/bin/awg /data/awg/
chmod 755 /data/awg/amneziawg-go /data/awg/awg
sha256sum /data/awg/amneziawg-go /data/awg/awg
rm -rf /tmp/awgx /tmp/awg-src.tar.gz
```

Контрольные суммы сохраните себе: по ним потом видно, не подменились ли файлы. Если ссылка перестала работать (автор мог выпустить новую версию), откройте страницу проекта и возьмите актуальный архив `…-source.tar.gz`: внутри должны быть `bin/amneziawg-go` и `bin/awg`.

### 1.2 Проверьте, что бинарники запускаются

**Роутер**

```bash
/data/awg/awg --version
```

*Вывод — ожидаемо*

```text
amneziawg-tools v3.1.20260812 - https://amnezia.org
```

> [!TIP]
> **Проверка**
>
> Версия печатается. Ошибки `Exec format error` или `not found` означают, что скачались файлы не под ту архитектуру.

Это сторонние сборки. Если не хотите им доверять, соберите сами: [часть 13, «Сборка бинарников для роутера»](#build). Для этого нужен сервер с Go, то есть сначала шаг 3.1.

<a name="p2"></a>

## 2. Профиль-«рельса» и правила PBR

Штатный VPN Client UniFi поддерживает только обычный WireGuard. Зато когда вы создаёте профиль VPN Client и правило Policy-Based Route, UniFi сам делает всю «механику» отбора трафика: метит пакеты нужных устройств и доменов и отправляет их в отдельную таблицу маршрутов. Этот профиль мы и используем как рельсу: в его таблицу сторож положит маршрут на AWG-туннель.

### 2.1 Сгенерируйте конфиг для рельсы

Подойдёт любой корректный WireGuard-конфиг. Проще всего сделать фиктивный: свои ключи, несуществующий сервер из документационного диапазона `192.0.2.0/24`. Туннель этого профиля никогда не поднимется, и это нормально.

**Роутер** · создаёт /tmp/rail.conf

```bash
cd /data/awg
RK=$(./awg genkey); RP=$(./awg genkey | ./awg pubkey)
cat > /tmp/rail.conf <<EOF
[Interface]
PrivateKey = $RK
Address = 10.255.255.2/32

[Peer]
PublicKey = $RP
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.1:51820
EOF
unset RK RP
cat /tmp/rail.conf
```

Перенесите файл на компьютер одним из способов: скопируйте текст из терминала в файл `rail.conf` или заберите его командой:

**ПК**

```bash
scp root@192.168.1.1:/tmp/rail.conf .
```

> [!NOTE]
> **Если у вас уже есть обычный WireGuard-конфиг**
>
> Например, от того же провайдера. Его можно поставить рельсой вместо фиктивного. Тогда он ещё и станет третьим резервом: его маршрут в таблице имеет метрику 37, хуже наших 5, но лучше blackhole. В нашей установке рельсой был старый WireGuard-канал, после его отключения всё продолжило работать.

### 2.2 Создайте профиль VPN Client

**UniFi** · Settings → VPN → VPN Client

```bash
Create New → VPN Type: WireGuard
Name:  AWG-rail
Configuration: Upload File → rail.conf  (или вручную: ключ, адрес, peer, endpoint)
Apply / Save
```

Профиль останется в статусе «не подключён» или с ошибкой. **Не выключайте и не удаляйте его:** вместе с ним UniFi уберёт метку и таблицу, и PBR-трафик перестанет попадать в туннель.

### 2.3 Создайте правило Policy-Based Route

**UniFi** · Settings → Routing → Policy-Based Routes (в старых версиях Traffic Routes)

```bash
Create Entry
Interface / VPN:  AWG-rail
Source:           устройства или сети, которые пускаем в туннель
Destination:      Any, домены или IP-адреса
Kill Switch:      On
Save
```

> [!WARNING]
> **Тестовое устройство останется без интернета до конца части 5**
>
> Рельса не поднимается, а с включённым Kill Switch UniFi блокирует трафик правила, пока сторож из части 5 не положит маршрут на AWG-туннель. Поэтому первое правило делайте для одного тестового устройства, а не для всей сети или для своего рабочего компьютера.

Для первой проверки достаточно одного правила: одно тестовое устройство, назначение Any. Остальные правила добавите потом, их число и вид роли не играют: все они ведут в одну таблицу. В нашей установке их было десять: по доменам и по адресам.

### 2.4 Определите таблицу и метку

У каждого роутера номер таблицы, метка и имя профиля свои (у нас были `178`, `0x6a0000` и `wgclt1`). Скрипт найдёт их сам и запишет в `/data/awg/awg.env`.

**Роутер** · создать awg-detect.sh

```bash
cat > /data/awg/awg-detect.sh <<'EOF'
#!/bin/bash
# awg-detect.sh — находит PBR-обвязку UniFi (таблица, метка, профиль-«рельса»)
# и записывает её в /data/awg/awg.env.
#   awg-detect.sh            если профиль VPN Client один
#   awg-detect.sh wgclt2     если профилей несколько: укажите нужный
# Систему не меняет. Ваши MAIN/BACKUP/VPS_IP/RECOVER_SEC/EXTRA_SUBNETS сохраняются.
DD=${DD:-/data/awg}
mkdir -p "$DD"
[ -r "$DD/awg.env" ] && . "$DD/awg.env"

# Правило PBR профиля UniFi выглядит так:
#   32504:  from all fwmark 0x6a0000/0x7e0000 lookup 178.wgclt1
rules=$(ip -4 rule show | awk '
  /fwmark/ && /lookup [0-9]+\.[a-z]+clt[0-9]+/ {
    prio=$1; sub(":","",prio); m=""; t=""
    for(i=1;i<=NF;i++){ if($i=="fwmark") m=$(i+1); if($i=="lookup") t=$(i+1) }
    split(t,a,"."); print prio, m, a[1], a[2]
  }')

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
chmod 600 "$DD/awg.env"
echo
echo "Записано в $DD/awg.env:"
sed 's/^/  /' "$DD/awg.env"
EOF
chmod 755 /data/awg/awg-detect.sh
/data/awg/awg-detect.sh
rm -f /tmp/rail.conf
```

*Вывод — пример вывода*

```text
Найдено PBR-правил VPN Client: 1
  приоритет 32504, метка 0x6a0000/0x7e0000, таблица 178, профиль wgclt1

Записано в /data/awg/awg.env:
  TABLE=178
  MARK=0x6a0000/0x7e0000
  PRIO=32504
  RAIL_IF=wgclt1
  WANIF=eth3
  MAIN=awgmain
  BACKUP=
  ...
```

> [!TIP]
> **Проверка**
>
> Строка «Найдено PBR-правил: 1». Если правил не нашлось, значит, профиль выключен или на него не ссылается ни одно правило PBR. Если профилей VPN Client несколько, скрипт попросит указать нужный: `/data/awg/awg-detect.sh wgclt2`.

<a name="p3"></a>

## 3. Свой сервер AmneziaWG на VPS

В сценарии B это ваш единственный туннель, в сценарии C это запасной канал. На сервере ставится тот же `amneziawg-go` из тех же исходников, что и на роутере, поэтому версии протокола совпадают. Сервер живёт отдельно от любых панелей, порт по умолчанию `51823/udp`, подсеть туннеля `10.0.1.0/24`.

> [!WARNING]
> **Не делайте это через 3x-ui / Xray**
>
> Xray-core не поддерживает AmneziaWG. А его WireGuard-inbound в нашей установке не записывал peers в рабочий `config.json`: порт слушался, пакеты приходили, но сервер молча их отбрасывал. Если на VPS стоит 3x-ui, пусть стоит, просто выберите для AWG свободный порт.

### 3.1 Соберите amneziawg-go и awg

**VPS** · сборка, ~3–5 минут

```bash
cat > /root/awg-server-build.sh <<'EOF'
#!/bin/bash
# awg-server-build.sh — сборка amneziawg-go и awg на VPS (Ubuntu 22.04/24.04, x86_64), от root.
# Исходники берутся из того же архива, что и бинарники для роутера: версии протокола совпадут.
set -e
SRC_URL=${SRC_URL:-https://github.com/DjGreeZ/AmneziaWG-Unifi-DreamMachine/raw/main/AmneziaWG-UniFi-v0.2.1-source.tar.gz}
apt-get update -q
apt-get install -y -q git make gcc curl
# Go: snap (Ubuntu) или официальный архив go.dev (Debian и системы без snap)
if ! command -v go >/dev/null 2>&1 && [ ! -x /snap/bin/go ] && [ ! -x /usr/local/go/bin/go ]; then
  if ! { command -v snap >/dev/null 2>&1 && snap install go --classic; }; then
    case "$(uname -m)" in x86_64) GA=amd64;; aarch64) GA=arm64;; *) echo "неизвестная архитектура $(uname -m)"; exit 1;; esac
    curl -fL "https://go.dev/dl/go1.23.4.linux-$GA.tar.gz" -o /tmp/go.tgz
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
  fi
fi
export PATH=$PATH:/snap/bin:/usr/local/go/bin
export GOTOOLCHAIN=auto   # если исходникам нужна более новая версия Go, она скачается сама
mkdir -p /root/awgbuild && cd /root/awgbuild
rm -rf go tools source
curl -fL "$SRC_URL" -o src.tar.gz
tar xzf src.tar.gz
mkdir -p go tools
tar xzf source/awg-go.tar.gz -C go
tar xzf source/awg-tools.tar.gz -C tools
( cd go/amneziawg-go-*/ && go build -o /usr/local/bin/amneziawg-go . )
( cd tools/amneziawg-tools-*/src && make && install -m 755 wg /usr/local/bin/awg )
echo
amneziawg-go --version | head -1
awg --version
EOF
chmod 755 /root/awg-server-build.sh
/root/awg-server-build.sh
```

*Вывод — конец вывода*

```text
amneziawg-go 0.0.20250522
amneziawg-tools v3.1.20260812 - https://amnezia.org
```

> [!TIP]
> **Проверка**
>
> Обе версии напечатались. Утилита собирается под именем `wg` и устанавливается как `/usr/local/bin/awg`, чтобы не путаться с обычным WireGuard.

### 3.2 Создайте сервер, ключи и конфиг для роутера

Скрипт генерирует ключи и параметры обфускации, пишет `/etc/amnezia/server.conf` и конфиг клиента для роутера, ставит службу `awg-server` (автозапуск, NAT, `ip_forward`) и открывает порт в ufw, если он включён. Повторный запуск ключи не трогает, только переустанавливает автозапуск.

**VPS** · создать awg-server-setup.sh

```bash
cat > /root/awg-server-setup.sh <<'EOF'
#!/bin/bash
# awg-server-setup.sh — сервер AmneziaWG на VPS (от root, после awg-server-build.sh).
# Создаёт ключи, параметры обфускации, /etc/amnezia/server.conf, конфиг клиента для роутера
# и службу awg-server (автозапуск, NAT, ip_forward).
#   VPS_IP=203.0.113.10 ./awg-server-setup.sh
# Необязательно: PORT=51823 SUBNET=10.0.1 MTU=1380
#   OBF_FILE=/root/obf.txt — взять Jc/Jmin/Jmax/S1/S2/H1-H4 из файла (например, из конфига,
#   который точно проходит через вашего провайдера); иначе параметры генерируются случайно.
set -e
PORT=${PORT:-51823}
SUBNET=${SUBNET:-10.0.1}
MTU=${MTU:-1380}
ETC=/etc/amnezia
OUT=/root/awgbuild
[ -d /data/unifi-core ] && { echo "Это роутер UniFi. Скрипт запускается на VPS."; exit 1; }
command -v awg >/dev/null && command -v amneziawg-go >/dev/null || { echo "Сначала awg-server-build.sh"; exit 1; }
umask 077; mkdir -p $ETC $OUT

if [ -e $ETC/server.conf ]; then
  echo "$ETC/server.conf уже есть: ключи не трогаю, переустанавливаю только автозапуск."
else
  VPS_IP=${VPS_IP:?задайте внешний IP сервера: VPS_IP=203.0.113.10 $0}
  if ss -ulpn | grep -q ":$PORT "; then echo "UDP-порт $PORT занят, выберите другой: PORT=... $0"; exit 1; fi
  if [ -n "$OBF_FILE" ]; then
    OBF=$(grep -E '^[[:space:]]*(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)[[:space:]]*=' "$OBF_FILE" | sed 's/^[[:space:]]*//')
    [ "$(echo "$OBF" | wc -l)" = 9 ] || { echo "В $OBF_FILE нужно ровно 9 строк Jc..H4"; exit 1; }
  else
    rnd(){ shuf -i "$1"-"$2" -n 1; }
    JC=$(rnd 4 8); JMIN=$(rnd 40 80); JMAX=$((JMIN + $(rnd 60 200)))
    S1=$(rnd 15 150); S2=$(rnd 15 150)
    while [ $((S1+56)) -eq $S2 ] || [ $S1 -eq $S2 ]; do S2=$(rnd 15 150); done
    mapfile -t HH < <(shuf -i 5-2147483647 -n 4)
    OBF=$(printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\nH1 = %s\nH2 = %s\nH3 = %s\nH4 = %s' \
      $JC $JMIN $JMAX $S1 $S2 ${HH[0]} ${HH[1]} ${HH[2]} ${HH[3]})
  fi
  SK=$(awg genkey); SP=$(echo "$SK" | awg pubkey)
  CK=$(awg genkey); CP=$(echo "$CK" | awg pubkey)
  cat > $ETC/server.conf <<CONF
[Interface]
PrivateKey = $SK
ListenPort = $PORT
$OBF

[Peer]
PublicKey = $CP
AllowedIPs = $SUBNET.2/32
CONF
  cat > $OUT/client.conf <<CONF
[Interface]
PrivateKey = $CK
Address = $SUBNET.2/32
MTU = $MTU
$OBF

[Peer]
PublicKey = $SP
AllowedIPs = 0.0.0.0/0
Endpoint = $VPS_IP:$PORT
PersistentKeepalive = 25
CONF
  chmod 600 $ETC/server.conf $OUT/client.conf
  echo "Созданы $ETC/server.conf и $OUT/client.conf"
fi

cat > /usr/local/bin/awg-up.sh <<UP
#!/bin/bash
ip link show awg0 >/dev/null 2>&1 && exit 0
amneziawg-go awg0
for k in 1 2 3 4 5 6 7 8 9 10; do ip link show awg0 >/dev/null 2>&1 && break; sleep 0.3; done
awg setconf awg0 $ETC/server.conf
ip addr add $SUBNET.1/24 dev awg0
ip link set awg0 up mtu $MTU
IFACE=\$(ip -4 route show default | awk '{print \$5; exit}')
iptables -t nat -C POSTROUTING -s $SUBNET.0/24 -o \$IFACE -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $SUBNET.0/24 -o \$IFACE -j MASQUERADE
iptables -C FORWARD -i awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -i awg0 -j ACCEPT
iptables -C FORWARD -o awg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD -o awg0 -j ACCEPT
UP
chmod 755 /usr/local/bin/awg-up.sh

cat > /etc/systemd/system/awg-server.service <<'UNIT'
[Unit]
Description=AmneziaWG server awg0
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/awg-up.sh
ExecStop=/sbin/ip link del awg0

[Install]
WantedBy=multi-user.target
UNIT

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg.conf
sysctl -q -p /etc/sysctl.d/99-awg.conf
P=$(awk -F'=' '/^ListenPort/{gsub(/ /,"",$2); print $2}' $ETC/server.conf)
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow "$P/udp"; fi
systemctl daemon-reload
ip link show awg0 >/dev/null 2>&1 && ip link del awg0
systemctl enable --now awg-server
echo
awg show awg0 | head -4 || true
ss -ulpn | grep ":$P " || echo "ВНИМАНИЕ: UDP $P пока не слушается: journalctl -u awg-server -n 20"
echo
echo "Конфиг для роутера: $OUT/client.conf (перенесите на роутер как /data/awg/backup.conf или main.conf)"
echo "Не забудьте открыть UDP $P в файрволе хостера, если он есть."
EOF
chmod 755 /root/awg-server-setup.sh
VPS_IP=203.0.113.10 /root/awg-server-setup.sh
```

*Вывод — конец вывода*

```text
interface: awg0
  public key: …
  private key: (hidden)
  listening port: 51823
UNCONN 0 0 0.0.0.0:51823 0.0.0.0:* users:(("amneziawg-go",pid=…,fd=4))

Конфиг для роутера: /root/awgbuild/client.conf
```

> [!NOTE]
> **Параметры обфускации: случайные или проверенные**
>
> По умолчанию `Jc, Jmin, Jmax, S1, S2, H1–H4` генерируются случайно с соблюдением правил AWG (например, `S1 + 56 ≠ S2`). Если у вас уже есть конфиг AWG, который точно проходит через вашего провайдера, можно взять параметры из него. В нашей установке так и сделали:
>
> **VPS** · вариант: параметры из проверенного конфига
>
> ```bash
> # положите в файл строки Jc..H4 (только их, без ключей!)
> nano /root/obf.txt
> OBF_FILE=/root/obf.txt VPS_IP=203.0.113.10 /root/awg-server-setup.sh
> ```
>
> Совпадение параметров с чужим сервером ничем не грозит: ключи и адреса у вас свои. Важно только, чтобы параметры на сервере и в `client.conf` совпадали, а скрипт это гарантирует.

### 3.3 Откройте порт у хостера

Если у хостера есть свой файрвол (Security Groups, «Сетевой экран» в панели), разрешите в нём входящий `UDP 51823`. Скрипт его не видит. Признак закрытого порта: на сервере `tcpdump -ni any udp port 51823` молчит, пока роутер шлёт handshake.

### 3.4 Перенесите конфиг на роутер

Сценарий C: файл станет запасным туннелем `backup.conf`. Сценарий B: это ваш основной туннель, назовите его `main.conf`.

**Роутер** · сценарий C

```bash
scp root@203.0.113.10:/root/awgbuild/client.conf /data/awg/backup.conf
chmod 600 /data/awg/backup.conf
grep -c '^Jc' /data/awg/backup.conf
```

**Роутер** · сценарий B

```bash
scp root@203.0.113.10:/root/awgbuild/client.conf /data/awg/main.conf
chmod 600 /data/awg/main.conf
grep -c '^Jc' /data/awg/main.conf
```

`grep` должен вывести `1`. Если `scp` недоступен, выведите файл на сервере (`cat /root/awgbuild/client.conf`), а на роутере выполните `cat > /data/awg/backup.conf`, вставьте текст и нажмите <kbd>Ctrl</kbd>+<kbd>D</kbd>. Когда файл на месте, удалите копию с сервера:

**VPS**

```bash
shred -u /root/awgbuild/client.conf
```

### 3.5 Аудит сервера

**VPS** · создать audit-server.sh

```bash
cat > /root/audit-server.sh <<'EOF'
#!/bin/bash
# audit-server.sh — проверка VPS с сервером AmneziaWG. Только чтение.
[ -d /data/unifi-core ] && { echo "Это роутер UniFi: запускайте на VPS"; exit 1; }
ok=0; warn=0; bad=0
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
P(){ echo "  ${G}OK${N}    $1"; ok=$((ok+1)); }
W(){ echo "  ${Y}WARN${N}  $1"; [ -n "$2" ] && echo "        fix: $2"; warn=$((warn+1)); }
F(){ echo "  ${R}FAIL${N}  $1"; [ -n "$2" ] && echo "        fix: $2"; bad=$((bad+1)); }
sec(){ echo; echo "${B}== $1 ==${N}"; }
CONF=/etc/amnezia/server.conf
PORT=$(awk -F'=' '/^ListenPort/{gsub(/ /,"",$2); print $2}' $CONF 2>/dev/null)

sec "AmneziaWG (awg0)"
ip link show awg0 >/dev/null 2>&1 && P "awg0 поднят" || F "awg0 отсутствует" "systemctl restart awg-server; journalctl -u awg-server -n 20"
en=$(systemctl is-enabled awg-server 2>/dev/null)
[ "$en" = enabled ] && P "awg-server: автозапуск включён" || F "awg-server: ${en:-не найден}" "awg-server-setup.sh"
c=$(pgrep -c amneziawg-go 2>/dev/null); [ "${c:-0}" = 1 ] && P "процессов amneziawg-go: 1" || W "процессов amneziawg-go: ${c:-0} (нужен 1)" "pgrep -a amneziawg-go"
if ip link show awg0 >/dev/null 2>&1; then
  np=$(awg show awg0 peers 2>/dev/null | wc -l); [ "$np" -ge 1 ] && P "peer на awg0: $np" || W "на awg0 нет peer" "awg show awg0"
  ts=$(awg show awg0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  if [ -n "$ts" ] && [ "$ts" != 0 ]; then P "handshake роутера: $(( $(date +%s) - ts ))с назад"; else W "handshake с роутера не было" "проверьте туннель на роутере"; fi
fi
[ "$(stat -c %a $CONF 2>/dev/null)" = 600 ] && P "$CONF: права 600" || W "$CONF: нет файла или права не 600" "chmod 600 $CONF"
[ -n "$PORT" ] && { ss -ulpn 2>/dev/null | grep ":$PORT " | grep -q amneziawg-go && P "UDP $PORT слушает amneziawg-go" || F "UDP $PORT не слушается amneziawg-go" "ss -ulpn | grep :$PORT"; }

sec "Маршрутизация и NAT"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && P "ip_forward = 1" || F "ip_forward не 1" "sysctl -w net.ipv4.ip_forward=1"
ls /etc/sysctl.d/*awg* /etc/sysctl.d/*wg* >/dev/null 2>&1 && P "ip_forward закреплён в /etc/sysctl.d" || W "ip_forward не закреплён" "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg.conf"
SUB=$(ip -4 -br addr show awg0 2>/dev/null | awk '{print $3}' | cut -d. -f1-3)
if [ -n "$SUB" ]; then
  c=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-s $SUB.0/24")
  [ "$c" = 1 ] && P "NAT для $SUB.0/24: 1 правило" || W "NAT для $SUB.0/24: $c (нужно 1)" "iptables -t nat -S POSTROUTING"
fi
c=$(iptables -S FORWARD 2>/dev/null | grep -c -E -- '(-i|-o) awg0 -j ACCEPT')
[ "$c" = 2 ] && P "FORWARD для awg0: 2 правила" || W "FORWARD для awg0: $c (нужно 2)" "iptables -S FORWARD | grep awg0"

sec "Файрвол"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw status | grep -q "^$PORT/udp" && P "ufw: $PORT/udp открыт" || F "ufw: $PORT/udp не открыт" "ufw allow $PORT/udp"
else
  echo "        ufw не активен: его правила не применяются"
fi
echo "        Файрвол в панели хостера скрипт не видит: UDP $PORT должен быть открыт и там."

sec "Файлы с ключами"
for f in /root/awgbuild/client.conf /root/awgbuild/server.conf; do
  [ -e "$f" ] && W "остаток: $f (после переноса на роутер не нужен)" "shred -u $f"
done
k=$(grep -E -c '[A-Za-z0-9+/]{43}=' /root/.bash_history 2>/dev/null)
[ "${k:-0}" = 0 ] && P "в .bash_history нет строк, похожих на ключи" || W ".bash_history: строк, похожих на ключи: $k" "history -c; : > /root/.bash_history"

sec "Итог"
echo "  ${G}OK: $ok${N}   ${Y}WARN: $warn${N}   ${R}FAIL: $bad${N}"
echo "  Скрипт ничего не меняет."
EOF
chmod 755 /root/audit-server.sh
/root/audit-server.sh
```

> [!TIP]
> **Проверка**
>
> Все пункты OK, кроме «handshake с роутера не было»: роутер ещё не подключён. Запустите аудит повторно: в сценарии B после шага 4.2, в сценарии C после шага 6.1. Там должно появиться «handshake роутера: …с назад».

<a name="p4"></a>

## 4. Основной туннель awgmain

Конфиг AmneziaWG кладётся в `/data/awg/main.conf` как есть, со всеми строками. Скрипт `up.sh` сам выкинет то, что утилита `awg` не понимает (`Address`, `DNS`, `MTU`, директивы wg-quick), назначит адрес и MTU и оставит в `AllowedIPs` только IPv4: маршрутами управляет сторож, а IPv6 через туннель не идёт.

### 4.1 Положите конфиг

Сценарий B: файл уже на месте после шага 3.4, пропустите. Сценарии A и C: вставьте конфиг провайдера прямо в терминал роутера (в чат, мессенджер или тикет его не отправляйте):

**Роутер** · вставьте конфиг и нажмите Ctrl+D

```bash
cat > /data/awg/main.conf
```

**Роутер**

```bash
chmod 600 /data/awg/main.conf
grep -E -c '^(Address|Endpoint|Jc)' /data/awg/main.conf
```

Должно получиться `3`. Поддерживаются конфиги AWG 1.x, 2.0 и 3.1: в нашей установке основной конфиг провайдера был по протоколу 3.1 и содержал `S3`, `S4`, `I1 = <r 198>`, `HeaderProtectionKey`, `RekeyAfterTime` и т. п., и бинарник из части 1 их принял.

### 4.2 Создайте up.sh и поднимите туннель

**Роутер** · создать up.sh

```bash
cat > /data/awg/up.sh <<'EOF'
#!/bin/bash
# up.sh — поднимает туннели AmneziaWG из конфигов в /data/awg
#   up.sh            все туннели: MAIN и, если задан, BACKUP (из awg.env)
#   up.sh awgmain    один туннель (интерфейс пересоздаётся; так применяют новый конфиг)
# Конфиги: main.conf — основной, backup.conf — запасной.
DD=${DD:-/data/awg}
cd "$DD" || exit 1
[ -r awg.env ] && . ./awg.env
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}
umask 077

conf_of(){
  if [ "$1" = "$MAIN" ]; then echo main.conf
  elif [ -n "$BACKUP" ] && [ "$1" = "$BACKUP" ]; then
    if [ -f backup.conf ] || [ ! -f client.conf ]; then echo backup.conf; else echo client.conf; fi
  fi
}

bring_up(){
  local n=$1 conf raw tmp addr mtu k
  conf=$(conf_of "$n")
  [ -z "$conf" ] && { echo "ОШИБКА: $n не указан в awg.env как MAIN или BACKUP"; return 1; }
  [ -f "$conf" ] || { echo "ОШИБКА: нет файла $DD/$conf"; return 1; }
  raw=/run/$n.raw; tmp=/run/$n.awg.conf
  sed 's/\r$//' "$conf" > "$raw"
  # Address и MTU утилита awg не понимает: берём их сами, из Address только IPv4
  addr=$(awk -F'=' 'tolower($1) ~ /^[ \t]*address[ \t]*$/ {print $2; exit}' "$raw" | tr ',' '\n' | tr -d ' \t' | grep -m1 '\.')
  mtu=$(awk -F'=' 'tolower($1) ~ /^[ \t]*mtu[ \t]*$/ {gsub(/[ \t]/,"",$2); print $2; exit}' "$raw")
  [ -z "$addr" ] && { echo "ОШИБКА: в $conf нет IPv4-адреса в строке Address"; rm -f "$raw"; return 1; }
  case "$addr" in */*) ;; *) addr=$addr/32 ;; esac
  [ -z "$mtu" ] && mtu=1380
  # убираем директивы wg-quick; маршрутизирует сторож, поэтому AllowedIPs = только IPv4 default
  grep -v -i -E '^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' "$raw" \
    | sed -E 's/^[[:space:]]*AllowedIPs[[:space:]]*=.*/AllowedIPs = 0.0.0.0\/0/' > "$tmp"
  rm -f "$raw"

  ip link show "$n" >/dev/null 2>&1 && ip link del "$n"
  ./amneziawg-go "$n" >/dev/null 2>&1
  for k in 1 2 3 4 5 6 7 8 9 10; do ip link show "$n" >/dev/null 2>&1 && break; sleep 0.3; done
  if ! ./awg setconf "$n" "$tmp"; then
    echo "ОШИБКА: awg setconf $n (строка, которую awg не понял, указана выше)"
    ip link del "$n" 2>/dev/null; rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
  ip addr add "$addr" dev "$n"
  ip link set "$n" up mtu "$mtu"
  sysctl -qw "net.ipv4.conf.$n.rp_filter=0" 2>/dev/null
  echo "$n поднят: адрес $addr, MTU $mtu, конфиг $conf"
}

if [ -n "$1" ]; then bring_up "$1"; exit $?; fi
rc=0
bring_up "$MAIN" || rc=1
if [ -n "$BACKUP" ]; then bring_up "$BACKUP" || rc=1; fi
exit $rc
EOF
chmod 755 /data/awg/up.sh
/data/awg/up.sh awgmain
```

*Вывод — ожидаемо*

```text
awgmain поднят: адрес 10.8.2.13/32, MTU 1406, конфиг main.conf
```

### 4.3 Проверьте туннель с самого роутера

**Роутер**

```bash
curl -s -m 8 --interface awgmain https://ifconfig.me; echo
/data/awg/awg show awgmain | grep -E 'endpoint|handshake|transfer'
```

*Вывод — ожидаемо*

```text
198.51.100.20                         ← внешний IP сервера VPN, не ваш домашний
  endpoint: 198.51.100.20:51822
  latest handshake: 3 seconds ago
  transfer: 4.12 KiB received, 1.98 KiB sent
```

> [!TIP]
> **Проверка**
>
> `curl` показывает IP сервера VPN, handshake свежий, `received` больше нуля. Если в конфиге нет `PersistentKeepalive`, handshake появляется только после первого трафика, поэтому сначала идёт `curl`.

> [!WARNING]
> **Если не так**
>
> - `ОШИБКА: awg setconf` и строка с непонятным параметром: бинарник старее конфига. Соберите свежий ([часть 13, «Сборка бинарников для роутера»](#build)) или попросите у провайдера конфиг без новых параметров.
> - Handshake нет, `received: 0 B`: пакеты не доходят или сервер их не принимает. Смотрите [часть 12, «Handshake не проходит»](#hs).
> - Handshake есть, но `ping -I awgmain 1.1.1.1` молчит, а `curl` работает: у части провайдеров ICMP через туннель не ходит. Это не поломка, сторож проверяет канал по HTTPS.

<a name="p5"></a>

## 5. Сторож и автозапуск

После этой части основа готова: PBR-трафик идёт в туннель, после перезагрузки всё поднимается само, а при падении туннеля трафик блокируется, а не утекает. Сторож — один скрипт под systemd. Он поднимает туннели, если их нет, держит NAT, MSS clamping и разрешения форварда, проверяет каналы и раз в 5 секунд подтверждает маршрут в таблице PBR: UniFi при перепровижне может её пересобрать.

| Параметр          | Значение                          | Что значит                                                                                                      |
|-------------------|-----------------------------------|-----------------------------------------------------------------------------------------------------------------|
| Проверка канала   | каждые 5 с                        | HTTPS к `1.1.1.1` и `8.8.8.8` через интерфейс туннеля; если не ответил, то ping. Живой, если ответил хоть один. |
| Падение           | 3 сбоя подряд, ~15 с              | При запасном канале: переключение на него, если он жив. Без запасного: запись в журнал, трафик блокируется.     |
| Возврат           | `RECOVER_SEC`, по умолчанию 600 с | Основной должен отвечать 10 минут без единого сбоя. Любой сбой обнуляет отсчёт.                                 |
| Запасной сломался | 3 сбоя                            | Если основной в этот момент жив, возврат на него сразу, без ожидания.                                           |
| Оба канала лежат  | —                                 | Маршрут остаётся на основном, за ним `blackhole`: PBR-трафик стоит, в WAN не утекает.                           |

### 5.1 Создайте сторожа и службу

**Роутер** · создать failover.sh

```bash
cat > /data/awg/failover.sh <<'EOF'
#!/bin/bash
# failover.sh — сторож: держит AWG-туннель в таблице PBR UniFi и переключает каналы.
#   failover.sh            основной цикл (запускает systemd: awg-failover.service)
#   failover.sh cleanup    убрать свои маршруты из таблицы PBR
# Параметры: /data/awg/awg.env (создаёт awg-detect.sh).
DD=${DD:-/data/awg}
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
    ip link show "$i" >/dev/null 2>&1 && continue
    [ "${NEXT_TRY[$i]:-0}" -gt "$now" ] && continue
    NEXT_TRY[$i]=$((now + 30))
    log "$i отсутствует, поднимаю"
    "$DD/up.sh" "$i" >/dev/null 2>&1 || log "$i: не удалось поднять (проверьте: $DD/up.sh $i)"
  done
}

set_active(){
  local a=$1 o
  if [ "$a" = "$MAIN" ]; then o=$BACKUP; else o=$MAIN; fi
  ip route replace default dev "$a" metric $METRIC table "$TABLE"
  [ -n "$o" ] && ip route del default dev "$o" table "$TABLE" 2>/dev/null
  ip route replace blackhole default metric 200 table "$TABLE" 2>/dev/null
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

state=$MAIN; fails=0; bfails=0; ok_since=0; both_flag=0
log "старт: основной $MAIN, запасной ${BACKUP:-нет}, таблица $TABLE, возврат через ${RECOVER_SEC}с"

while true; do
  ensure_tunnels
  prepare

  if [ "$state" = "$MAIN" ]; then
    if check "$MAIN"; then
      [ $both_flag -eq 1 ] && log "ВОССТАНОВЛЕН канал $MAIN, трафик по PBR снова идёт"
      fails=0; both_flag=0
    else
      fails=$((fails+1))
    fi
    if [ $fails -ge $FAIL_MAX ]; then
      if [ -n "$BACKUP" ] && check "$BACKUP"; then
        state=$BACKUP; fails=0; bfails=0; ok_since=0; both_flag=0
        log "ПЕРЕКЛЮЧЕНИЕ на запасной канал $BACKUP"
      elif [ $both_flag -eq 0 ]; then
        both_flag=1
        if [ -n "$BACKUP" ]; then log "оба канала не отвечают, остаюсь на $MAIN (трафик по PBR блокируется)"
        else log "единственный канал $MAIN не отвечает (трафик по PBR блокируется)"; fi
      fi
    fi
  else
    if check "$MAIN"; then
      [ $ok_since -eq 0 ] && { ok_since=$(date +%s); log "основной снова отвечает, жду ${RECOVER_SEC}с без сбоев"; }
      if [ $(( $(date +%s) - ok_since )) -ge "$RECOVER_SEC" ]; then
        state=$MAIN; fails=0; ok_since=0
        log "ВОЗВРАТ на основной канал $MAIN"
      fi
    else
      [ $ok_since -ne 0 ] && log "основной снова сбоит, отсчёт возврата сброшен"
      ok_since=0
    fi
    if [ "$state" = "$BACKUP" ]; then
      if check "$BACKUP"; then bfails=0; else bfails=$((bfails+1)); fi
      if [ $bfails -ge $FAIL_MAX ] && check "$MAIN"; then
        state=$MAIN; fails=0; bfails=0; ok_since=0
        log "запасной не отвечает, основной жив: возврат на $MAIN"
      fi
    fi
  fi

  set_active "$state"
  sleep "$INTERVAL"
done
EOF
chmod 755 /data/awg/failover.sh
```

**Роутер** · служба systemd (копия хранится в /data/awg)

```bash
cat > /data/awg/awg-failover.service <<'EOF'
[Unit]
Description=AmneziaWG failover for UniFi PBR
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/data/awg/failover.sh
ExecStopPost=/data/awg/failover.sh cleanup
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cp /data/awg/awg-failover.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now awg-failover
```

### 5.2 Проверьте таблицу PBR

**Роутер**

```bash
sleep 8
. /data/awg/awg.env; ip route show table $TABLE
tail -n 3 /data/awg/failover.log
```

*Вывод — ожидаемо*

```text
default dev wgclt1 proto VPN scope link metric 37     ← маршрут UniFi (может отсутствовать, если рельса не поднята)
default dev awgmain scope link metric 5
blackhole default metric 200
2026-10-11 09:00:01 старт: основной awgmain, запасной нет, таблица 178, возврат через 600с
```

> [!TIP]
> **Проверка**
>
> В таблице ровно один маршрут `dev awg…` с `metric 5` и `blackhole` с `metric 200`.

### 5.3 Проверьте с устройств

| Устройство       | Откройте 2ip.io или ifconfig.me         |
|------------------|-----------------------------------------|
| Под правилом PBR | IP сервера VPN (тот же, что в шаге 4.3) |
| Вне PBR          | Ваш обычный домашний IP                 |

Если правило PBR по доменам, проверяйте на сайте из списка: 2ip.io при этом может показать домашний адрес, и это верно.

### 5.4 Перезагрузите роутер

Когда никто не пользуется сетью, перезагрузите роутер и через 2–3 минуты повторите шаги 5.2 и 5.3. Сразу после загрузки сторож ждёт 30 секунд, пока UniFi соберёт свои правила.

### 5.5 Подготовьтесь к обновлениям прошивки

Обновление UniFi может очистить `/etc/systemd/system` и `/root/.bashrc`. Раздел `/data` сохраняется, а с ним и копии всех юнитов. Этот скрипт возвращает автозапуск одной командой. Он восстанавливает только то, что у вас установлено: панель, Telegram и очистку баннера из частей 8–10, если вы их потом поставите, тоже.

**Роутер** · создать awg-restore.sh

```bash
cat > /data/awg/awg-restore.sh <<'EOF'
#!/bin/bash
# awg-restore.sh — вернуть автозапуск и панель после обновления прошивки
# (UniFi может очистить /etc/systemd/system и /root/.bashrc; /data при этом сохраняется).
D=/data/awg
cp "$D/awg-failover.service" /etc/systemd/system/
NOTIFY=0; MOTD=0
[ -f "$D/awg-notify.service" ] && [ -f "$D/telegram.env" ] && { NOTIFY=1; cp "$D/awg-notify.service" /etc/systemd/system/; }
[ -f "$D/awg-motd.service" ] && [ -f "$D/motd.orig" ] && { MOTD=1; cp "$D/awg-motd.service" /etc/systemd/system/; }
systemctl daemon-reload
systemctl enable --now awg-failover
[ $NOTIFY = 1 ] && systemctl enable --now awg-notify
[ $MOTD = 1 ] && systemctl enable --now awg-motd
# панель и команды возвращаются, только если соответствующая часть ставилась
# установщик отмечает выбранные компоненты файлами .panel/.audit; при ручной установке по гайду
# признак — наличие самих скриптов
want(){ [ -f "$D/.$1" ] || { [ -x "$D/$2" ] && [ ! -f "$D/.installer" ]; }; }
if want panel status.sh && ! grep -q AWGS_SHOWN /root/.bashrc 2>/dev/null; then
  cat >> /root/.bashrc <<'RC'
alias awgs='/data/awg/status.sh'
case $- in *i*) [ -n "$SSH_CONNECTION" ] && [ -z "$AWGS_SHOWN" ] && { export AWGS_SHOWN=1; /data/awg/status.sh; } ;; esac
RC
fi
if want audit audit.sh && ! grep -q "alias awg-audit=" /root/.bashrc 2>/dev/null; then
  echo "alias awg-audit='/data/awg/audit.sh'" >> /root/.bashrc
fi
[ -f "$D/motd.orig" ] && touch /root/.hushlogin
[ -x "$D/install.sh" ] && ! grep -q "alias awg-setup=" /root/.bashrc 2>/dev/null && echo "alias awg-setup='/data/awg/install.sh'" >> /root/.bashrc
if [ -x "$D/audit.sh" ]; then echo "Готово. Проверьте: $D/audit.sh"; else echo "Готово. Проверьте: systemctl is-active awg-failover"; fi
EOF
chmod 755 /data/awg/awg-restore.sh
```

Запускать сейчас не нужно. Как пользоваться после обновления, описано в [части 11](#p11).

<a name="p6"></a>

## 6. Запасной канал и автопереключение

Нужны готовый сервер из части 3 и `/data/awg/backup.conf` на роутере. Запасной туннель держится поднятым постоянно, поэтому переключение занимает около 15 секунд, а не время на подключение.

### 6.1 Включите запасной туннель

**Роутер**

```bash
sed -i 's/^BACKUP=.*/BACKUP=awgbackup/; s/^VPS_IP=.*/VPS_IP=203.0.113.10/' /data/awg/awg.env
/data/awg/up.sh awgbackup
curl -s -m 8 --interface awgbackup https://ifconfig.me; echo
systemctl restart awg-failover
sleep 5; tail -n 2 /data/awg/failover.log
```

*Вывод — ожидаемо*

```text
awgbackup поднят: адрес 10.0.1.2/32, MTU 1380, конфиг backup.conf
203.0.113.10
2026-10-11 09:10:02 остановка: маршруты убраны
2026-10-11 09:10:02 старт: основной awgmain, запасной awgbackup, таблица 178, возврат через 600с
```

Перезапуск сторожа даёт около 5 секунд без PBR-трафика. Теперь на сервере `/root/audit-server.sh` должен показать свежий handshake роутера.

### 6.2 Проверьте переключение

Падение основного канала имитируется файлом-флагом: пока он есть, сторож считает основной мёртвым. Раньше мы имитировали сбой правилом iptables, но UniFi пересобирал свои цепочки и стирал его. Флаг надёжнее.

**Роутер** · падение

```bash
touch /tmp/awg-sim-down
sleep 20; . /data/awg/awg.env; ip route show table $TABLE; tail -n 2 /data/awg/failover.log
```

*Вывод — ожидаемо*

```text
default dev awgbackup scope link metric 5
blackhole default metric 200
2026-10-11 09:12:20 ПЕРЕКЛЮЧЕНИЕ на запасной канал awgbackup
```

Устройство под PBR теперь показывает IP вашего VPS. Уже открытые соединения рвутся и переподключаются сами: у них меняется внешний адрес.

**Роутер** · возврат

```bash
rm /tmp/awg-sim-down
tail -f /data/awg/failover.log
```

Сразу появится «основной снова отвечает, жду 600с без сбоев», через 10 минут «ВОЗВРАТ на основной канал awgmain». Выход из `tail`: <kbd>Ctrl</kbd>+<kbd>C</kbd>.

> [!NOTE]
> **Быстрый тест без 10 минут ожидания**
>
> Остановите службу и запустите сторожа вручную с коротким возвратом. Во втором окне SSH делайте `touch` и `rm` флага. <kbd>Ctrl</kbd>+<kbd>C</kbd> корректно убирает маршруты (раньше версия без обработчика оставляла маршрут запасного канала, так что после теста обязательно верните службу).
>
> **Роутер**
>
> ```bash
> systemctl stop awg-failover
> RECOVER_SEC=60 /data/awg/failover.sh
> # ... тест, затем Ctrl+C и:
> systemctl start awg-failover
> ```

### 6.3 Время возврата

Меняется в `/data/awg/awg.env` (`RECOVER_SEC=600`), затем `systemctl restart awg-failover`.

<a name="p7"></a>

## 7. Клиенты VPN-сервера роутера через туннель

Если на UDR7 работает VPN-сервер (WireGuard Server или Teleport) и вы хотите, чтобы его клиенты, например ваш телефон вне дома, тоже ходили через AWG по тем же правилам PBR. UniFi применяет PBR к источникам из своего списка локальных сетей (ipset `UBIOS4local_network`), а подсети VPN-сервера в нём может не быть. Сторож умеет держать их в этом списке и возвращает их туда каждые 5 секунд, если UniFi пересоберёт ipset.

> [!NOTE]
> **Проверено на одной установке**
>
> Клиент WireGuard-сервера роутера (подсеть 192.168.3.0/24) после этого выходил в интернет с IP туннеля по правилам PBR. Как именно это сработает у вас, зависит от того, как задан источник в правиле PBR, поэтому обязательно сделайте проверку в конце.

### 7.1 Узнайте подсеть VPN-сервера

Она указана в настройках сервера: Settings → VPN → VPN Server. Или посмотрите адреса интерфейсов на роутере:

**Роутер**

```bash
ip -4 -br addr | grep -v -E '^(lo|eth|br|awg|wgclt)'
```

### 7.2 Добавьте подсеть в awg.env

**Роутер** · подставьте свою подсеть; несколько через пробел

```bash
sed -i 's|^EXTRA_SUBNETS=.*|EXTRA_SUBNETS="192.168.3.0/24"|' /data/awg/awg.env
systemctl restart awg-failover
sleep 6; ipset test UBIOS4local_network 192.168.3.0/24
```

*Вывод — ожидаемо*

```text
192.168.3.0/24 is in set UBIOS4local_network.
```

> [!TIP]
> **Проверка**
>
> С телефона, подключённого к VPN-серверу роутера по мобильному интернету, откройте сайт из правил PBR или 2ip.io (если правило на все адреса): должен быть IP туннеля.

<a name="p8"></a>

## 8. Панель состояния при входе по SSH

При каждом входе по SSH вместо стандартного баннера UniFi вы видите сводку: состояние (HEALTHY / DEGRADED / CRITICAL), предупреждения, активный канал, handshake и скорость обоих туннелей, нагрузку, последние 20 событий, где лежат файлы и шпаргалку команд. Вызвать вручную можно командой `awgs`.

> [!NOTE]
> **Части 8–11 независимы**
>
> Панель, аудит, Telegram и обслуживание не требуют друг друга: ставьте любые и в любом порядке, лишь бы были готовы части 0–5. Скрипты сами смотрят, что установлено: панель показывает строки про аудит и восстановление, только если эти скрипты есть, аудит проверяет панель и Telegram, только если их ставили, а `awg-restore.sh` возвращает только то, что было.

### 8.1 Скрипт панели

**Роутер** · создать status.sh

```bash
cat > /data/awg/status.sh <<'EOF'
#!/bin/bash
# awgs — панель состояния AmneziaWG failover (только чтение)
#   awgs        полная панель    awgs -s   кратко    awgs -i   с внешними IP туннелей
DD=${DD:-/data/awg}
AWG=${AWG:-$DD/awg}
LOG=$DD/failover.log
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
TABLE=${TABLE:-0}; MARK=${MARK:-0x0/0x0}; RAIL_IF=${RAIL_IF:-wgclt1}; WANIF=${WANIF:-eth3}
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; IFACES="$MAIN${BACKUP:+ $BACKUP}"
MODE=full; WANT_IP=0
for a in "$@"; do case $a in
  -s) MODE=short;;
  -i) WANT_IP=1;;
  -h|--help) echo "awgs [-s кратко] [-i внешние IP через туннели]"; exit 0;;
esac; done

if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else G=; R=; Y=; C=; B=; D=; N=; fi

W=78
if [ "$AWGS_ASCII" = 1 ]; then LN='-'; else LN='━'; fi
rep(){ local s='' k; for ((k=0;k<$2;k++)); do s+=$1; done; printf '%s' "$s"; }
hdr(){ local t=" $1 "; echo "${D}$(rep "$LN" 2)${N}${B}${t}${N}${D}$(rep "$LN" $((W-${#t}-2)))${N}"; }
hum(){ awk -v b="${1:-0}" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++} if(i==1) printf("%d %s",b,u[i]); else printf("%.1f %s",b,u[i])}'; }
mbit(){ awk -v b="${1:-0}" 'BEGIN{printf("%.2f",b*8/1000000)}'; }
age_s(){ local ts; ts=$($AWG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }
age_f(){ local s=$1; if [ "$s" -lt 0 ]; then echo never; elif [ "$s" -lt 120 ]; then echo "${s}s"; elif [ "$s" -lt 7200 ]; then echo "$((s/60))m$((s%60))s"; elif [ "$s" -lt 172800 ]; then echo "$((s/3600))h$(((s%3600)/60))m"; else echo "$((s/86400))d"; fi; }
st_of(){ local a=$1; if [ "$a" -lt 0 ]; then echo DOWN; elif [ "$a" -lt 180 ]; then echo UP; elif [ "$a" -lt 900 ]; then echo IDLE; else echo STALE; fi; }
col_of(){ case $1 in UP) printf '%s' "$G";; IDLE) printf '%s' "$Y";; *) printf '%s' "$R";; esac; }
rd(){ cat "/sys/class/net/$1/statistics/$2" 2>/dev/null || echo 0; }

declare -A r0 t0 r1 t1
for i in $IFACES; do r0[$i]=$(rd $i rx_bytes); t0[$i]=$(rd $i tx_bytes); done
sleep 1
for i in $IFACES; do r1[$i]=$(rd $i rx_bytes); t1[$i]=$(rd $i tx_bytes); done

rt=$(ip route show table "$TABLE" 2>/dev/null)
active=$(echo "$rt" | awk '$1=="default"{for(i=1;i<=NF;i++) if($i=="dev" && $(i+1) ~ /^awg/){print $(i+1); exit}}')
svc=$(systemctl is-active awg-failover 2>/dev/null)
a_main=$(age_s "$MAIN"); a_bak=-1; [ -n "$BACKUP" ] && a_bak=$(age_s "$BACKUP")
s_main=$(st_of $a_main); s_bak=$(st_of $a_bak)

alerts=(); level=0
add(){ alerts+=("$2|$1"); [ "$2" -gt "$level" ] && level=$2; }
[ "$TABLE" = 0 ] && add "Нет $DD/awg.env: запустите awg-detect.sh" 2
[ "$svc" != active ] && add "Сторож awg-failover не запущен (systemctl start awg-failover)" 2
[ -z "$active" ] && add "В таблице PBR $TABLE нет маршрута на AWG-туннель: трафик по PBR не проходит" 2
[ -n "$BACKUP" ] && [ "$active" = "$BACKUP" ] && add "Работает ЗАПАСНОЙ канал, основной: $s_main" 1
[ "$active" = "$MAIN" ] && [ "$s_main" != UP ] && add "Основной канал: handshake $s_main ($(age_f $a_main))" 1
[ -n "$BACKUP" ] && [ "$s_bak" != UP ] && add "Запасной канал: $s_bak, защиты от падения основного нет" 1
[ -e /tmp/awg-sim-down ] && add "Включён флаг имитации падения /tmp/awg-sim-down (rm /tmp/awg-sim-down)" 1
ip rule show 2>/dev/null | grep -q "fwmark ${MARK%%/*}" || add "Нет PBR-правила fwmark ${MARK%%/*}" 2
for f in main.conf backup.conf client.conf telegram.env awg.env; do
  [ -e "$DD/$f" ] && [ "$(stat -c %a "$DD/$f" 2>/dev/null)" != 600 ] && add "Права $DD/$f не 600 (chmod 600 $DD/$f)" 1
done
du_pct=$(df /data 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
[ -n "$du_pct" ] && [ "$du_pct" -ge 90 ] && add "Раздел /data заполнен на ${du_pct}%" 1

case $level in
  0) badge="${G}${B}● HEALTHY${N}";;
  1) badge="${Y}${B}▲ DEGRADED${N}";;
  *) badge="${R}${B}✖ CRITICAL${N}";;
esac

echo
echo "${B}${C}AmneziaWG Failover${N}  ${D}$(hostname) · $(date '+%F %T') · $(uptime -p 2>/dev/null)${N}"
hdr "STATUS"
if [ -n "$active" ] && [ "$active" = "$MAIN" ]; then ap="${G}${B}$active${N} (основной)"
elif [ -n "$active" ]; then ap="${Y}${B}$active${N} (ЗАПАСНОЙ)"
else ap="${R}${B}нет${N}"; fi
[ "$svc" = active ] && sv="${G}active${N}" || sv="${R}${svc:-unknown}${N}"
echo " Состояние    : $badge"
echo " Канал PBR    : $ap"
echo " Сторож       : $sv"
lastline=$(grep -E "ПЕРЕКЛЮЧЕНИЕ|ВОЗВРАТ|возврат на" "$LOG" 2>/dev/null | tail -n 1)
if [ -n "$lastline" ]; then
  lts=$(date -d "${lastline:0:19}" +%s 2>/dev/null)
  la=""; [ -n "$lts" ] && la=" ($(age_f $(( $(date +%s) - lts ))) назад)"
  echo " Последняя смена: ${lastline}${la}"
  echo " Переключений в логе: $(grep -c 'ПЕРЕКЛЮЧЕНИЕ' "$LOG" 2>/dev/null)"
fi
if [ -n "$BACKUP" ]; then
  iv=${INTERVAL:-5}; fm=${FAIL_MAX:-3}
  echo " Политика     : проверка каждые ${iv}с, переключение после ${fm} сбоев (~$((iv*fm))с), возврат после ${RECOVER_SEC:-600}с без сбоев"
else
  echo " Политика     : один туннель, проверка каждые ${INTERVAL:-5}с; если он упал, PBR-трафик блокируется (без утечки в WAN)"
fi
if [ $WANT_IP = 1 ]; then
  for i in $IFACES; do ( curl -s -m 4 --interface $i https://ifconfig.me > /tmp/awgs.$i 2>/dev/null ) & done; wait
  echo " Внешний IP   : $(for i in $IFACES; do printf '%s=%s  ' $i "$(cat /tmp/awgs.$i 2>/dev/null)"; done)"
  rm -f /tmp/awgs.*
fi

if [ ${#alerts[@]} -gt 0 ]; then
  echo
  hdr "ALERTS"
  for e in "${alerts[@]}"; do
    l=${e%%|*}; m=${e#*|}
    if [ "$l" = 2 ]; then echo " ${R}✖${N} $m"; else echo " ${Y}▲${N} $m"; fi
  done
fi

echo
hdr "TUNNELS"
printf "${B}   %-10s %-7s %-7s %-9s %-22s %10s %10s %8s %8s${N}\n" TUNNEL ROLE STATE HANDSHK ENDPOINT RX TX "DN Mb/s" "UP Mb/s"
for i in $IFACES; do
  if [ "$i" = "$MAIN" ]; then role=main; a=$a_main; s=$s_main; else role=backup; a=$a_bak; s=$s_bak; fi
  mark=" "; [ "$i" = "$active" ] && mark="▶"
  if ! ip link show "$i" >/dev/null 2>&1; then
    printf " %s ${B}%-10s${N} %-7s ${R}%-7s${N}\n" "$mark" "$i" "$role" "NO-IFACE"; continue
  fi
  ep=$($AWG show "$i" endpoints 2>/dev/null | awk 'NR==1{print $2}')
  read -r rx tx < <($AWG show "$i" transfer 2>/dev/null | awk '{r+=$2;t+=$3} END{print r+0, t+0}')
  dr=$(( ${r1[$i]} - ${r0[$i]} )); dt=$(( ${t1[$i]} - ${t0[$i]} ))
  printf " %s ${B}%-10s${N} %-7s $(col_of $s)%-7s${N} %-9s %-22s %10s %10s %8s %8s\n" "$mark" "$i" "$role" "$s" "$(age_f $a)" "${ep:--}" "$(hum $rx)" "$(hum $tx)" "$(mbit $dr)" "$(mbit $dt)"
done
ip link show "$RAIL_IF" >/dev/null 2>&1 && echo " ${D}  $RAIL_IF: профиль-«рельса» UniFi, держит PBR-правило, трафик не несёт${N}"
echo " ${D}▶ активный канал PBR · скорость за 1 с внутри туннеля · UP = handshake < 3 мин${N}"

echo
hdr "SYSTEM"
load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
mem=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d/%d MiB (%d%%)",$3,$2,$3*100/$2}')
disk=$(df -h /data 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')
temp=""; for z in /sys/class/thermal/thermal_zone*/temp; do [ -r "$z" ] && { temp=" · temp $(( $(cat "$z") / 1000 ))°C"; break; }; done
wan=$(ip -4 -br addr show "$WANIF" 2>/dev/null | awk '{print $2, $3}')
echo " Нагрузка : ${load:-?} · RAM ${mem:-?} · /data ${disk:-?}${temp}"
echo " WAN $WANIF : ${wan:-нет данных}"
if systemctl is-enabled awg-notify >/dev/null 2>&1; then echo " Telegram : awg-notify $(systemctl is-active awg-notify 2>/dev/null)"; fi

echo
hdr "EVENTS (last 20)"
if [ -s "$LOG" ]; then ev=$(tail -n 20 "$LOG"); else ev=$(journalctl -t awg-failover -n 20 --no-pager -o short 2>/dev/null | sed -E 's/ [^ ]+ awg-failover(\[[0-9]+\])?:/ /'); fi
[ -z "$ev" ] && ev="(событий пока нет)"
echo "$ev" | sed -e "s/^/ /" -e "s/ПЕРЕКЛЮЧЕНИЕ/${R}&${N}/" -e "s/ВОЗВРАТ/${G}&${N}/" -e "s/ВОССТАНОВЛЕН/${G}&${N}/" -e "s/не отвечает/${Y}&${N}/" -e "s/оба канала/${R}&${N}/"

[ "$MODE" = short ] && { echo; exit 0; }

f(){ printf " ${C}%-48s${N} %s\n" "$1" "$2"; }
echo
hdr "FILES"
f "$DD/awg.env" "параметры: таблица PBR, метка, имена туннелей, возврат"
f "$DD/main.conf" "конфиг основного туннеля ($MAIN), ключи, chmod 600"
[ -n "$BACKUP" ] && f "$DD/backup.conf" "конфиг запасного туннеля ($BACKUP), ключи"
f "$DD/up.sh" "поднять туннели: up.sh [имя туннеля]"
f "$DD/failover.sh" "сторож: проверка, переключение, возврат"
f "$DD/failover.log" "журнал сторожа (~1000 строк)"
f "$DD/status.sh" "эта панель (awgs)"
[ -x "$DD/audit.sh" ] && f "$DD/audit.sh" "аудит (awg-audit)"
f "/etc/systemd/system/awg-*.service" "автозапуск (копии юнитов в $DD)"
[ -x "$DD/awg-restore.sh" ] && f "$DD/awg-restore.sh" "вернуть автозапуск после обновления прошивки"
[ -n "$VPS_IP" ] && f "сервер $VPS_IP: /etc/amnezia/server.conf" "сервер запасного канала (служба awg-server)"

echo
hdr "CHEAT SHEET"
f "awgs | awgs -s | awgs -i" "панель | кратко | с внешними IP"
[ -x "$DD/audit.sh" ] && f "awg-audit" "проверка на лишние правила и файлы (только чтение)"
f "tail -f $DD/failover.log" "события сторожа в реальном времени"
f "ip route show table $TABLE" "активный канал PBR (metric 5)"
f "$DD/awg show $MAIN" "детали туннеля"
f "curl -s --interface $MAIN https://ifconfig.me" "внешний IP через туннель"
[ -n "$BACKUP" ] && f "touch /tmp/awg-sim-down  /  rm /tmp/awg-sim-down" "имитация падения основного / отмена"
f "$DD/up.sh $MAIN" "применить новый main.conf"
f "systemctl restart awg-failover" "перезапуск сторожа (~5 с без PBR-трафика)"
echo
EOF
chmod 755 /data/awg/status.sh
/data/awg/status.sh
```

### 8.2 Показ при входе и команда awgs

**Роутер**

```bash
grep -q AWGS_SHOWN /root/.bashrc 2>/dev/null || cat >> /root/.bashrc <<'RC'
alias awgs='/data/awg/status.sh'
case $- in *i*) [ -n "$SSH_CONNECTION" ] && [ -z "$AWGS_SHOWN" ] && { export AWGS_SHOWN=1; /data/awg/status.sh; } ;; esac
RC
```

Панель выводится только в интерактивной сессии, поэтому `scp` и `rsync` не ломаются. Если терминал неправильно рисует линии, добавьте в `/root/.bashrc` строку `export AWGS_ASCII=1`. Живой режим: `watch -n2 -c '/data/awg/status.sh -s'`.

### 8.3 Уберите стандартный баннер UniFi

Баннер с логотипом и текстом NOTICE берётся из `/etc/motd`. Строка `PrintMotd no` в sshd его не отключает. Оригинал сохраняем в `/data/awg/motd.orig`, файл очищаем, а маленькая служба очищает его при каждой загрузке, если прошивка его вернёт.

**Роутер** · /data/awg/awg-motd.service

```bash
touch /root/.hushlogin
cp -a /etc/motd /data/awg/motd.orig
: > /etc/motd
cat > /data/awg/awg-motd.service <<'EOF'
[Unit]
Description=Clear UniFi SSH banner (/etc/motd)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c ': > /etc/motd'

[Install]
WantedBy=multi-user.target
EOF
cp /data/awg/awg-motd.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable awg-motd
```

Откройте **новое** окно SSH: должна появиться только панель. Если панели нет, ваша оболочка не читает `.bashrc`: добавьте в `/root/.profile` строку `[ -f ~/.bashrc ] && . ~/.bashrc`.

*Вывод — так выглядит панель (пример, без цветов)*

```text
AmneziaWG Failover  UDR7 · 2026-10-11 09:31:25 · up 3 days, 2 hours
━━ STATUS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Состояние    : ● HEALTHY
 Канал PBR    : awgmain (основной)
 Сторож       : active
 Последняя смена: 2026-10-10 08:22:50 ВОЗВРАТ на основной канал awgmain (1d)
 Переключений в логе: 1
 Политика     : проверка каждые 5с, переключение после 3 сбоев (~15с), возврат после 600с без сбоев

━━ TUNNELS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   TUNNEL     ROLE    STATE   HANDSHK   ENDPOINT                       RX         TX  DN Mb/s  UP Mb/s
 ▶ awgmain    main    UP      41s       198.51.100.20:51822     812.4 MiB   96.1 MiB     3.41     0.52
   awgbackup  backup  UP      72s       203.0.113.10:51823        2.1 MiB    1.9 MiB     0.00     0.00
   wgclt1: профиль-«рельса» UniFi, держит PBR-правило, трафик не несёт

━━ SYSTEM ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Нагрузка : 0.31 0.28 0.25 · RAM 1201/1952 MiB (61%) · /data 2.1G/9.8G (22%) · temp 58°C
 WAN eth3 : UP 188.0.2.34/24
 Telegram : awg-notify active

━━ EVENTS (last 20) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 2026-10-10 08:12:40 ПЕРЕКЛЮЧЕНИЕ на запасной канал awgbackup
 2026-10-10 08:12:58 основной снова отвечает, жду 600с без сбоев
 2026-10-10 08:22:50 ВОЗВРАТ на основной канал awgmain
 ...
(дальше FILES и CHEAT SHEET)
```

<a name="p9"></a>

## 9. Аудит установки

После экспериментов на роутере остаются лишние правила, дубли, тестовые флаги и файлы с ключами. Именно так было у нас: аудит нашёл забытую старую службу, третий процесс `amneziawg-go`, дубли NAT и FORWARD от двух одновременно запущенных сторожей и ключи в истории команд. `awg-audit` ничего не меняет, а только показывает OK / WARN / FAIL с готовой командой исправления.

**Роутер** · создать audit.sh

```bash
cat > /data/awg/audit.sh <<'EOF'
#!/bin/bash
# awg-audit — проверка установки на роутере: службы, туннели, правила, файлы. Только чтение.
DD=${DD:-/data/awg}
AWG=${AWG:-$DD/awg}
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
TABLE=${TABLE:-0}; MARK=${MARK:-0x0/0x0}; RAIL_IF=${RAIL_IF:-wgclt1}
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TUNS="$MAIN${BACKUP:+ $BACKUP}"
NT=$(echo $TUNS | wc -w)
ok=0; warn=0; bad=0
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=; R=; Y=; B=; N=; fi
P(){ echo "  ${G}OK${N}    $1"; ok=$((ok+1)); }
W(){ echo "  ${Y}WARN${N}  $1"; [ -n "$2" ] && echo "        fix: $2"; warn=$((warn+1)); }
F(){ echo "  ${R}FAIL${N}  $1"; [ -n "$2" ] && echo "        fix: $2"; bad=$((bad+1)); }
sec(){ echo; echo "${B}== $1 ==${N}"; }
age_s(){ local ts; ts=$($AWG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi; }

sec "Параметры"
if [ "$TABLE" = 0 ]; then F "нет $DD/awg.env" "$DD/awg-detect.sh"
else P "awg.env: таблица $TABLE, метка $MARK, рельса $RAIL_IF, туннели: $TUNS"; fi
for b in amneziawg-go awg; do [ -x "$DD/$b" ] && P "бинарник $b на месте" || F "нет $DD/$b" "часть 1, шаг 1.1"; done

sec "Службы и процессы"
st=$(systemctl is-active awg-failover 2>/dev/null); en=$(systemctl is-enabled awg-failover 2>/dev/null)
[ "$st" = active ] && P "awg-failover: active" || F "awg-failover: ${st:-нет}" "systemctl start awg-failover"
[ "$en" = enabled ] && P "awg-failover: автозапуск включён" || W "awg-failover: автозапуск ${en:-нет}" "systemctl enable awg-failover"
for u in awg-failover awg-notify awg-motd; do
  [ -f "$DD/$u.service" ] || continue
  [ $u = awg-notify ] && [ ! -f "$DD/telegram.env" ] && continue   # Telegram не настраивался
  [ $u = awg-motd ] && [ ! -f "$DD/motd.orig" ] && continue        # баннер не отключался
  cmp -s "/etc/systemd/system/$u.service" "$DD/$u.service" && P "$u.service совпадает с копией в $DD" \
    || W "$u.service в /etc отличается от копии в $DD или отсутствует" "cp $DD/$u.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now $u"
done
n=$(ps -eo pid,ppid,args | awk '/failover\.sh/ && !/awk/ && !/cleanup/ {p[$1]=$2; a[$1]=1} END{for(i in p) if(!(p[i] in a)) n++; print n+0}')
if [ "$st" = active ]; then [ "$n" = 1 ] && P "экземпляров failover.sh: 1" || W "экземпляров failover.sh: $n (нужен 1)" "systemctl stop awg-failover; pkill -f '/data/awg/failover[.]sh'; systemctl start awg-failover"
else [ "$n" = 0 ] && P "ручных экземпляров failover.sh нет" || W "failover.sh запущен вручную при остановленной службе" "pkill -f '/data/awg/failover[.]sh'; $DD/failover.sh cleanup"; fi
c=$(pgrep -c amneziawg-go 2>/dev/null); [ "${c:-0}" = "$NT" ] && P "процессов amneziawg-go: $NT" || W "процессов amneziawg-go: ${c:-0} (нужно $NT)" "pgrep -a amneziawg-go; лишний интерфейс: ip link del <имя>"
if [ -f "$DD/telegram.env" ]; then
  [ "$(systemctl is-active awg-notify 2>/dev/null)" = active ] && P "awg-notify: active" || W "awg-notify не запущен" "systemctl enable --now awg-notify"
fi

sec "Туннели"
for i in $TUNS; do ip link show "$i" >/dev/null 2>&1 && P "$i существует" || F "$i отсутствует" "$DD/up.sh $i"; done
for i in $TUNS; do
  a=$(age_s "$i")
  if [ "$a" -ge 0 ] && [ "$a" -lt 180 ]; then P "$i: handshake ${a}с назад"
  else W "$i: handshake давно или не было ($a)" "curl -s --interface $i https://ifconfig.me; $DD/awg show $i"; fi
done
ip link show "$RAIL_IF" >/dev/null 2>&1 && P "$RAIL_IF на месте (рельса PBR)" || W "$RAIL_IF отсутствует: UniFi мог убрать PBR-обвязку" "проверьте профиль VPN Client в UniFi, затем $DD/awg-detect.sh"

sec "Маршрутизация"
n=$(ip rule show | grep -c "fwmark ${MARK%%/*}")
[ "$n" = 1 ] && P "правило PBR fwmark ${MARK%%/*}: одно" || W "правил fwmark ${MARK%%/*}: $n (нужно 1)" "ip rule show"
t=$(ip route show table "$TABLE" 2>/dev/null)
echo "        таблица $TABLE:"; echo "$t" | sed 's/^/          /'
c=$(echo "$t" | grep -c 'dev awg')
[ "$c" = 1 ] && P "в таблице PBR ровно один AWG-маршрут" || { [ "$c" = 0 ] && F "в таблице PBR нет AWG-маршрута" "systemctl restart awg-failover" || W "AWG-маршрутов в таблице: $c (нужен 1)" "systemctl restart awg-failover"; }
echo "$t" | grep -q blackhole && P "blackhole на месте: при падении туннелей утечки в WAN нет" || W "в таблице нет blackhole" "systemctl restart awg-failover"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ] && P "ip_forward = 1" || F "ip_forward не 1" "sysctl -w net.ipv4.ip_forward=1"
for s in $EXTRA_SUBNETS; do
  ipset test UBIOS4local_network "$s" >/dev/null 2>&1 && P "подсеть $s в ipset UBIOS4local_network" || W "подсети $s нет в ipset" "сторож добавит её сам через 5 с; если нет — systemctl restart awg-failover"
done

sec "iptables"
for i in $TUNS; do
  c=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-o $i -j MASQUERADE")
  [ "$c" = 1 ] && P "NAT MASQUERADE на $i: 1" || W "NAT MASQUERADE на $i: $c (нужно 1)" "iptables -t nat -D POSTROUTING -o $i -j MASQUERADE  (до одного правила)"
done
d1=$(iptables -S FORWARD 2>/dev/null | sort | uniq -d); d2=$(iptables -t mangle -S FORWARD 2>/dev/null | sort | uniq -d)
[ -z "$d1$d2" ] && P "дублей в FORWARD (filter/mangle) нет" || W "дубли в FORWARD: $(echo "$d1$d2" | wc -l) строк" "iptables -S FORWARD | sort | uniq -d; удалите лишнюю копию: iptables -D ..."
iptables -S OUTPUT 2>/dev/null | grep -q -E 'icmp.*(DROP|REJECT)' && W "в OUTPUT есть DROP для icmp (остаток теста?)" "iptables -S OUTPUT"

sec "Файлы"
for f in main.conf ${BACKUP:+backup.conf} awg.env; do
  [ "$f" = backup.conf ] && [ ! -e "$DD/backup.conf" ] && [ -e "$DD/client.conf" ] && f=client.conf
  [ -e "$DD/$f" ] || { F "нет $DD/$f"; continue; }
  [ "$(stat -c %a "$DD/$f")" = 600 ] && P "$f: права 600" || W "$f: права $(stat -c %a "$DD/$f")" "chmod 600 $DD/$f"
done
[ -e "$DD/telegram.env" ] && { [ "$(stat -c %a "$DD/telegram.env")" = 600 ] && P "telegram.env: права 600" || W "telegram.env: права не 600" "chmod 600 $DD/telegram.env"; }
for f in /tmp/awg-src.tar.gz /tmp/awgx /tmp/awg-sim-down /tmp/rail.conf; do
  [ -e "$f" ] && W "остаток: $f" "rm -rf $f"
done
ls /run/*.awg.conf /run/*.raw >/dev/null 2>&1 && W "в /run остались временные конфиги с ключами" "rm -f /run/*.awg.conf /run/*.raw"
k=$(grep -E -c '[A-Za-z0-9+/]{43}=' /root/.bash_history 2>/dev/null)
[ "${k:-0}" = 0 ] && P "в .bash_history нет строк, похожих на ключи" || W ".bash_history: строк, похожих на ключи: $k" "history -c; : > /root/.bash_history"
if [ -f "$DD/.panel" ] || { [ -x "$DD/status.sh" ] && [ ! -f "$DD/.installer" ]; }; then
  grep -q AWGS_SHOWN /root/.bashrc 2>/dev/null && P "панель при входе по SSH настроена" || W "status.sh есть, но в /root/.bashrc нет показа панели" "часть 8, шаг 8.2"
fi

sec "Итог"
echo "  ${G}OK: $ok${N}   ${Y}WARN: $warn${N}   ${R}FAIL: $bad${N}"
echo "  Скрипт ничего не меняет. Команды fix выполняйте по одной, прочитав вывод."
EOF
chmod 755 /data/awg/audit.sh
grep -q "alias awg-audit=" /root/.bashrc 2>/dev/null || echo "alias awg-audit='/data/awg/audit.sh'" >> /root/.bashrc
/data/awg/audit.sh
```

Команда `awg-audit` появится в новом окне SSH. Панель из части 8 для аудита не нужна: если её нет, пункт про `.bashrc` просто пропускается.

*Вывод — пример здоровой установки*

```text
== Службы и процессы ==
  OK    awg-failover: active
  OK    экземпляров failover.sh: 1
  OK    процессов amneziawg-go: 2
== Маршрутизация ==
  OK    правило PBR fwmark 0x6a0000: одно
  OK    в таблице PBR ровно один AWG-маршрут
  OK    blackhole на месте: при падении туннелей утечки в WAN нет
...
== Итог ==
  OK: 27   WARN: 0   FAIL: 0
```

Команды из строк `fix:` выполняйте по одной, прочитав вывод. Если WARN про дубли не уходит через минуту, значит, работают два сторожа: `systemctl stop awg-failover; pkill -f '/data/awg/failover[.]sh'; systemctl start awg-failover`.

<a name="p10"></a>

## 10. Уведомления в Telegram

Два скрипта. `notify.sh` отправляет сообщение через основной туннель, при неудаче через запасной, потом напрямую через WAN; если не вышло нигде, сообщение откладывается и уходит при первой возможности. Токен передаётся через stdin, в списке процессов его не видно. `awg-notify.sh` читает журнал сторожа и присылает события, раз в минуту проверяет здоровье, а раз в сутки шлёт отчёт.

| Сообщение                                      | Когда                                                                                                  |
|------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| ⚠️ Переключение на запасной канал              | сразу, со снимком: активный канал, handshake, внешний IP                                               |
| ✅ Возврат на основной                         | сразу, плюс сколько проработали на запасном                                                            |
| 🛑 Нет рабочего канала / ✅ Канал восстановлен | не чаще раза в 5 минут                                                                                 |
| ⚠️ Запасной канал потерян                      | handshake запасного старше 5 минут три проверки подряд: самый опасный тихий сбой                       |
| 🛑 awg-failover остановлен                     | три проверки подряд                                                                                    |
| 📊 Суточный отчёт                              | в 09:00 по часам роутера: состояние, трафик за сутки, переключения, время на запасном, журнал, система |
| 🔄 Роутер загрузился                           | при старте службы                                                                                      |

### 10.1 Бот и chat id

1.  В Telegram откройте @BotFather → `/newbot` и получите токен. Заведите **отдельного** бота для роутера, не берите бота, который уже используется, например в 3x-ui: утечка одного токена не заденет другой.
2.  Откройте своего нового бота и нажмите **Start**: без этого бот не может вам писать (ошибка 400).
3.  Узнайте свой числовой chat id, например у бота @userinfobot. Это не секрет.

### 10.2 Сохраните токен на роутере

Токен вводится скрыто и в историю команд не попадает.

**Роутер**

```bash
read -rsp "Токен бота: " T; echo
read -rp "Ваш chat id: " C
printf 'TG_TOKEN=%s\nTG_CHAT=%s\n' "$T" "$C" > /data/awg/telegram.env
chmod 600 /data/awg/telegram.env; unset T C
```

Дополнительно в этот файл можно дописать `REPORT_TIME=0830` (время отчёта) и `TG_NO_WAN=1` (не слать напрямую через провайдера).

### 10.3 Скрипты

**Роутер** · создать notify.sh

```bash
cat > /data/awg/notify.sh <<'EOF'
#!/bin/bash
# notify.sh — отправка в Telegram с резервированием: основной туннель -> запасной -> WAN.
#   notify.sh [--html] "текст"
# Не доставилось никуда — сообщение откладывается в notify.spool и уходит при следующей удачной отправке.
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
. "$DD/telegram.env" || exit 2
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}

MODE=""
[ "$1" = "--html" ] && { MODE=html; shift; }
TEXT="${1:0:3900}"
[ -z "$TEXT" ] && exit 0

LOG=$DD/notify.log
SPOOL=$DD/notify.spool
# Порядок попыток. Пустая строка = напрямую через WAN. Если WAN не нужен, задайте TG_NO_WAN=1 в telegram.env.
IFACES=("$MAIN")
[ -n "$BACKUP" ] && IFACES+=("$BACKUP")
[ "${TG_NO_WAN:-0}" = 1 ] || IFACES+=("")

log() {
  echo "$(date '+%F %T') $*" >> "$LOG"
  if [ "$(wc -l < "$LOG")" -gt 300 ]; then tail -n 200 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"; fi
}

# $1=интерфейс или "", $2=таймаут, $3=текст. Токен идёт через stdin: в списке процессов его не видно.
send_via() {
  local args=(-4 -s -m "$2" -o /dev/null -w '%{http_code}')
  [ -n "$1" ] && args+=(--interface "$1")
  [ "$MODE" = html ] && args+=(--data-urlencode "parse_mode=HTML")
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_TOKEN" |
    curl "${args[@]}" -K - \
      --data-urlencode "chat_id=${TG_CHAT}" \
      --data-urlencode "text=$3" \
      --data-urlencode "disable_web_page_preview=true" 2>/dev/null
}

send_text() {
  local i to code
  for i in "${IFACES[@]}"; do
    if [ "$i" = "$MAIN" ]; then to=10; else to=15; fi
    code=$(send_via "$i" "$to" "$1")
    if [ "$code" = 200 ]; then
      [ "$i" != "$MAIN" ] && log "доставлено через ${i:-WAN}"
      return 0
    fi
    log "не удалось через ${i:-WAN}: HTTP ${code:-000}"
  done
  return 1
}

spool_add() {
  printf '%s|%s\n' "$MODE" "$(printf '%s' "$1" | base64 -w0)" >> "$SPOOL"
  chmod 600 "$SPOOL"
  tail -n 20 "$SPOOL" > "$SPOOL.t" && mv "$SPOOL.t" "$SPOOL"
}

spool_flush() {
  [ -s "$SPOOL" ] || return 0
  local m b t keep=$MODE
  mv "$SPOOL" "$SPOOL.run"
  while IFS='|' read -r m b; do
    t=$(printf '%s' "$b" | base64 -d)
    MODE=$m
    send_text "$t" || printf '%s|%s\n' "$m" "$b" >> "$SPOOL"
  done < "$SPOOL.run"
  rm -f "$SPOOL.run"
  MODE=$keep
}

# одна отправка за раз (событие и отчёт могут совпасть)
exec 9>/tmp/awg-notify.lock
command -v flock >/dev/null && flock -w 120 9

if send_text "$TEXT"; then
  spool_flush
  exit 0
fi
log "ВСЕ КАНАЛЫ НЕДОСТУПНЫ, сообщение отложено"
spool_add "🕓 (отложено, событие в $(date '+%F %T'))"$'\n'"$TEXT"
exit 1
EOF
chmod 700 /data/awg/notify.sh
```

**Роутер** · создать awg-notify.sh

```bash
cat > /data/awg/awg-notify.sh <<'EOF'
#!/bin/bash
# awg-notify.sh — уведомления в Telegram о работе failover.
#   awg-notify.sh          демон (запускает systemd: awg-notify.service)
#   awg-notify.sh report   отправить суточный отчёт сейчас
#   awg-notify.sh test     тестовое сообщение со снимком состояния
export LC_ALL=C.UTF-8
DD=${DD:-/data/awg}
AWG=$DD/awg
LOGF=$DD/failover.log
EV=$DD/notify.events          # epoch|тип (switch / return / both)
ST=$DD/notify.state           # счётчики трафика на момент прошлого отчёта
LASTREP=$DD/notify.lastreport
[ -r "$DD/awg.env" ] && . "$DD/awg.env"
[ -r "$DD/telegram.env" ] && . "$DD/telegram.env"
TABLE=${TABLE:-0}; MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}; TUNS="$MAIN${BACKUP:+ $BACKUP}"
REPORT_TIME=${REPORT_TIME:-0900}   # время суточного отчёта ЧЧММ по часам роутера (можно задать в telegram.env)
H=$(hostname)

# ---------- утилиты ----------
esc()  { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
trunc(){ cut -c1-"$1" | iconv -c -f UTF-8 -t UTF-8; }   # обрезка без битых символов
send() { "$DD/notify.sh" --html "$1" >/dev/null 2>&1; }
hum()  { awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u," "); i=1; while(b>=1024&&i<5){b/=1024;i++}; f=(i==1?"%d %s":"%.1f %s"); printf f, b, u[i]}'; }
cnt()  { cat "/sys/class/net/$1/statistics/$2_bytes" 2>/dev/null || echo 0; }
hs_age() {
  local ts
  ts=$($AWG show "$1" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  if [ -z "$ts" ] || [ "$ts" = 0 ]; then echo -1; else echo $(( $(date +%s) - ts )); fi
}
fa() {
  local a=$1
  if   [ "$a" -lt 0 ];    then echo "нет"
  elif [ "$a" -lt 120 ];  then echo "${a}с назад"
  elif [ "$a" -lt 7200 ]; then echo "$((a/60))м назад"
  else echo "$((a/3600))ч назад"; fi
}
fd() {
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dч %02dм' $((s/3600)) $((s%3600/60)); else printf '%dм %02dс' $((s/60)) $((s%60)); fi
}
active() {
  local r
  r=$(ip route show table "$TABLE" 2>/dev/null | awk '$1=="default" && /dev awg/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
  echo "${r:-none}"
}
extip() {
  local ip u
  [ "$1" = none ] && { echo "-"; return; }
  for u in https://api.ipify.org https://ifconfig.me; do
    ip=$(curl -4 -s -m 6 --interface "$1" "$u" 2>/dev/null)
    [[ "$ip" =~ ^[0-9.]+$ ]] && { echo "$ip"; return; }
  done
  echo "-"
}
health() {   # $1=active $2=возраст handshake основного $3=запасного
  if ! systemctl is-active --quiet awg-failover; then echo "CRITICAL: сторож awg-failover не работает"
  elif [ "$1" = none ]; then echo "CRITICAL: нет AWG-маршрута в таблице PBR"
  elif [ -n "$BACKUP" ] && [ "$1" = "$BACKUP" ]; then echo "DEGRADED: работаем на запасном канале"
  elif [ -n "$BACKUP" ] && { [ "$3" -lt 0 ] || [ "$3" -gt 300 ]; }; then echo "DEGRADED: запасной канал не отвечает"
  else echo "HEALTHY"; fi
}
snapshot() {
  local a t; a=$(active)
  echo "Активный канал : $a"
  for t in $TUNS; do printf '%-14s : handshake %s\n' "$t" "$(fa "$(hs_age "$t")")"; done
  echo "Внешний IP     : $(extip "$a")"
  echo "Время роутера  : $(date '+%F %T')"
}

# ---------- статистика ----------
evcount() { awk -F'|' -v w=$(( $(date +%s) - 86400 )) -v t="$1" '$2==t && $1>=w {n++} END{print n+0}' "$EV" 2>/dev/null || echo 0; }
backup_secs() {
  awk -F'|' -v now="$(date +%s)" 'BEGIN{w=now-86400; s=0; on=0; st=0}
    $2=="switch" { if(!on){on=1; st=($1<w?w:$1)} }
    $2=="return" { if(on){on=0; e=$1; if(e>st) s+=e-st} }
    END{ if(on) s+=now-st; print s+0 }' "$EV" 2>/dev/null || echo 0
}
delta() {
  local cur base
  cur=$(cnt "$1" "$2")
  base=$(awk -v i="$1" -v d="$2" '$1==i{print (d=="rx"?$2:$3)}' "$ST" 2>/dev/null)
  base=${base:-0}
  [ "$cur" -lt "$base" ] && base=0     # интерфейс пересоздавался
  echo $((cur - base))
}
save_base() { local i; for i in $TUNS; do echo "$i $(cnt "$i" rx) $(cnt "$i" tx)"; done > "$ST"; }

# ---------- суточный отчёт ----------
report() {
  local a m b ip up body journal evs t i
  a=$(active); m=$(hs_age "$MAIN"); b=-1; [ -n "$BACKUP" ] && b=$(hs_age "$BACKUP"); ip=$(extip "$a")
  up=$(awk '{s=int($1); printf "%dд %dч %dм", s/86400, s%86400/3600, s%3600/60}' /proc/uptime)
  evs=$(grep -E 'ПЕРЕКЛЮЧЕНИЕ|ВОЗВРАТ|ВОССТАНОВЛЕН|не отвечает' "$LOGF" 2>/dev/null | tail -5 | trunc 110)
  journal=$(tail -n 8 "$LOGF" 2>/dev/null | trunc 110)
  body=$(
    printf 'Состояние : %s\n' "$(health "$a" "$m" "$b")"
    printf 'Активный  : %s (внешний IP %s)\n' "$a" "$ip"
    printf 'Аптайм    : %s\n\n' "$up"
    printf '%-10s %-10s %-10s %s\n' Tunnel RX-24h TX-24h handshake
    for i in $TUNS; do
      printf '%-10s %-10s %-10s %s\n' "$i" "$(hum "$(delta "$i" rx)")" "$(hum "$(delta "$i" tx)")" "$(fa "$(hs_age "$i")")"
    done
    printf '\nСобытия за 24 ч:\n'
    if [ -n "$BACKUP" ]; then
      printf '  переключений на запасной: %s\n' "$(evcount switch)"
      printf '  возвратов на основной: %s\n' "$(evcount return)"
      printf '  время на запасном: %s\n' "$(fd "$(backup_secs)")"
    fi
    printf '  канал(ы) не отвечали: %s раз\n' "$(evcount both)"
    printf '\nПоследние события:\n'
    if [ -n "$evs" ]; then echo "$evs" | sed 's/^/  /'; else echo "  нет"; fi
    printf '\nЖурнал failover (последние 8 строк):\n'
    if [ -n "$journal" ]; then echo "$journal" | sed 's/^/  /'; else echo "  пусто"; fi
    printf '\nСистема:\n'
    printf '  нагрузка: %s\n' "$(cut -d' ' -f1-3 /proc/loadavg)"
    printf '  RAM: %s\n' "$(free -m | awk '/^Mem:/{print $3"/"$2" MB"}')"
    t=/sys/class/thermal/thermal_zone0/temp
    [ -r $t ] && printf '  температура: %s°C\n' $(( $(cat $t) / 1000 ))
    printf '  /data: %s\n' "$(df -h "$DD" | awk 'NR==2{print $5" занято, свободно "$4}')"
    printf '  службы: failover=%s notify=%s\n' "$(systemctl is-active awg-failover)" "$(systemctl is-active awg-notify)"
    printf '  процессов amneziawg-go: %s\n' "$(pgrep -c amneziawg-go)"
    printf '  сбоев доставки в Telegram за 24 ч: %s\n' "$(awk -v s="$(date -d '24 hours ago' '+%F %T')" '($1" "$2)>=s && /не удалось/{n++} END{print n+0}' "$DD/notify.log" 2>/dev/null)"
  )
  send "<b>📊 Суточный отчёт</b> · $H · $(date '+%F')"$'\n'"<pre>$(printf '%s' "$body" | esc)</pre>"
  save_base
  [ -f "$EV" ] && tail -n 500 "$EV" > "$EV.t" && mv "$EV.t" "$EV"
}

# ---------- реакция на строку журнала сторожа ----------
last_both=0
on_line() {
  local l="$1" now title extra lastsw
  now=$(date +%s)
  case "$l" in
    *ПЕРЕКЛЮЧЕНИЕ*)
      echo "$now|switch" >> "$EV"
      title="⚠️ Переключение на запасной канал"
      extra="Основной канал не проходит проверку. PBR-трафик идёт через $BACKUP." ;;
    *ВОЗВРАТ*|*"возврат на"*)
      lastsw=$(awk -F'|' '$2=="switch"{t=$1} END{print t}' "$EV" 2>/dev/null)
      echo "$now|return" >> "$EV"
      title="✅ Возврат на основной канал"
      extra="PBR-трафик снова через $MAIN."
      [ -n "$lastsw" ] && extra="$extra На запасном проработали: $(fd $((now - lastsw)))." ;;
    *"оба канала не отвечают"*|*"единственный канал"*)
      [ $((now - last_both)) -lt 300 ] && return
      last_both=$now
      echo "$now|both" >> "$EV"
      title="🛑 Нет рабочего канала"
      extra="PBR-трафик заблокирован (утечки в WAN нет)." ;;
    *ВОССТАНОВЛЕН*)
      title="✅ Канал восстановлен"
      extra="PBR-трафик снова идёт через $MAIN." ;;
    *) return ;;
  esac
  sleep 4   # даём маршрутам устояться
  send "<b>${title}</b> · $H"$'\n'"$(printf '%s' "$extra" | esc)"$'\n'"<pre>$(snapshot | esc)</pre>"$'\n'"<code>$(printf '%s' "$l" | trunc 200 | esc)</code>"
}

# ---------- фоновый контроль раз в минуту ----------
declare -A BAD ALR
chk() {   # $1=имя $2=1 если плохо $3=тревога $4=восстановление; тревога после 3 плохих проверок подряд
  local n=$1
  if [ "$2" = 1 ]; then
    BAD[$n]=$(( ${BAD[$n]:-0} + 1 ))
    if [ "${BAD[$n]}" -ge 3 ] && [ "${ALR[$n]:-0}" = 0 ]; then
      ALR[$n]=1; send "<b>$3</b> · $H"$'\n'"<pre>$(snapshot | esc)</pre>"
    fi
  else
    BAD[$n]=0
    if [ "${ALR[$n]:-0}" = 1 ]; then
      ALR[$n]=0; send "<b>$4</b> · $H"$'\n'"<pre>$(snapshot | esc)</pre>"
    fi
  fi
}
monitor() {
  local a bad
  while sleep 60; do
    if [ -n "$BACKUP" ]; then
      a=$(hs_age "$BACKUP"); bad=0; { [ "$a" -lt 0 ] || [ "$a" -gt 300 ]; } && bad=1
      chk backup "$bad" "⚠️ Запасной канал потерян: при падении основного переключаться некуда" "✅ Запасной канал восстановлен"
    fi
    a=$(hs_age "$MAIN"); bad=0; { [ "$a" -lt 0 ] || [ "$a" -gt 300 ]; } && bad=1
    chk main "$bad" "⚠️ $MAIN: handshake старше 5 минут" "✅ $MAIN: handshake в норме"
    bad=0; systemctl is-active --quiet awg-failover || bad=1
    chk svc "$bad" "🛑 awg-failover остановлен: автопереключения нет" "✅ awg-failover снова работает"
    if [ $((10#$(date +%H%M))) -ge $((10#$REPORT_TIME)) ] && [ "$(cat "$LASTREP" 2>/dev/null)" != "$(date +%F)" ]; then
      date +%F > "$LASTREP"
      report
    fi
  done
}

daemon() {
  local up t
  [ -f "$ST" ] || save_base
  monitor & MON=$!
  trap 'kill $MON 2>/dev/null' EXIT INT TERM
  sleep 20   # после загрузки даём туннелям подняться
  up=$(awk '{print int($1)}' /proc/uptime)
  if [ "$up" -lt 900 ]; then t="🔄 Роутер загрузился, наблюдатель запущен"; else t="🟢 Наблюдатель awg-notify перезапущен"; fi
  send "<b>$t</b> · $H"$'\n'"<pre>$(snapshot | esc)</pre>"
  tail -n0 -F "$LOGF" 2>/dev/null | while IFS= read -r l; do on_line "$l"; done
}

case "${1:-daemon}" in
  report) report ;;
  test)   if send "<b>✅ Тест уведомлений</b> · $H"$'\n'"<pre>$(snapshot | esc)</pre>"; then echo "отправлено"; else echo "ошибка, см. $DD/notify.log"; fi ;;
  daemon) daemon ;;
  *)      echo "использование: $0 [daemon|report|test]"; exit 1 ;;
esac
EOF
chmod 700 /data/awg/awg-notify.sh
```

### 10.4 Тест без службы

**Роутер**

```bash
/data/awg/awg-notify.sh test
/data/awg/awg-notify.sh report
cat /data/awg/notify.log 2>/dev/null
```

> [!TIP]
> **Проверка**
>
> В Telegram пришли два сообщения, `notify.log` пуст или его нет. Коды в логе: `401` означает неверный токен, `400` означает, что не нажат Start у бота, `000` означает, что Telegram недоступен по этому пути.

### 10.5 Служба

**Роутер** · /data/awg/awg-notify.service

```bash
cat > /data/awg/awg-notify.service <<'EOF'
[Unit]
Description=AmneziaWG failover Telegram notifications
After=awg-failover.service network-online.target

[Service]
ExecStart=/data/awg/awg-notify.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cp /data/awg/awg-notify.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now awg-notify
```

Через ~20 секунд придёт «Наблюдатель awg-notify перезапущен». В сценарии C проверьте событие: `touch /tmp/awg-sim-down`, через 15–20 секунд придёт «Переключение», затем `rm /tmp/awg-sim-down` и через 10 минут «Возврат».

Если роутер выключится целиком, сообщить об этом будет некому. Для такого случая нужен внешний мониторинг (например, healthchecks.io с пингом раз в 5 минут).

<a name="p11"></a>

## 11. Обслуживание

### После обновления прошивки UniFi

Обновление может очистить `/etc/systemd/system` и `/root/.bashrc`. Скрипт восстановления вы создали в шаге 5.5. После обновления выполните `/data/awg/awg-restore.sh`, затем проверьте `/data/awg/audit.sh` (если ставили часть 9) или `systemctl is-active awg-failover`. Если UniFi пересоздал профиль VPN Client, а метка или таблица поменялись, сначала `/data/awg/awg-detect.sh`, затем `systemctl restart awg-failover`. Если после крупного обновления UniFi перестанет создавать PBR-правило с меткой, схема работать не будет: проверьте `ip rule show | grep fwmark`.

### Частые операции

| Задача                         | Команды                                                                                                                                                                                                                                                                                |
|--------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Новый конфиг от провайдера     | замените `/data/awg/main.conf` (`cat >`, <kbd>Ctrl</kbd>+<kbd>D</kbd>, `chmod 600`), затем `/data/awg/up.sh awgmain`. Разрыв пара секунд.                                                                                                                  |
| Перевыпустить ключи своего VPS | на VPS: `systemctl stop awg-server; mv /etc/amnezia/server.conf /root/server.conf.old`, затем `VPS_IP=… /root/awg-server-setup.sh`. Новый `client.conf` перенесите на роутер (шаг 3.4) и выполните `/data/awg/up.sh awgbackup`. Старый файл удалите: `shred -u /root/server.conf.old`. |
| Время возврата, подсети        | правка `/data/awg/awg.env`, затем `systemctl restart awg-failover`                                                                                                                                                                                                                     |
| Пересоздали профиль VPN Client | `/data/awg/awg-detect.sh`, затем `systemctl restart awg-failover`                                                                                                                                                                                                                      |
| Временно отключить AWG         | `systemctl stop awg-failover`. Маршруты уберутся, PBR-трафик пойдёт по правилам UniFi, то есть в мёртвую рельсу или в kill switch.                                                                                                                                                     |
| Очистить историю команд        | `history -c; : > /root/.bash_history` на роутере и на VPS, в конце установки                                                                                                                                                                                                           |

### Полное удаление

**Роутер** · создать awg-uninstall.sh

```bash
cat > /data/awg/awg-uninstall.sh <<'EOF'
#!/bin/bash
# awg-uninstall.sh — полностью убрать установку с роутера.
#   awg-uninstall.sh          остановить и убрать службы, маршруты, правила, интерфейсы
#   awg-uninstall.sh --purge  то же + удалить /data/awg (конфиги с ключами тоже!)
D=/data/awg
[ -r $D/awg.env ] && . $D/awg.env
MAIN=${MAIN:-awgmain}; BACKUP=${BACKUP:-}
for u in awg-notify awg-failover awg-motd; do
  systemctl disable --now $u 2>/dev/null
  rm -f /etc/systemd/system/$u.service
done
systemctl daemon-reload
pkill -f "$D/failover[.]sh" 2>/dev/null
[ -x $D/failover.sh ] && $D/failover.sh cleanup 2>/dev/null
for i in $MAIN $BACKUP; do
  while iptables -t nat -D POSTROUTING -o $i -j MASQUERADE 2>/dev/null; do :; done
  while iptables -t mangle -D FORWARD -o $i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
  while iptables -t mangle -D FORWARD -i $i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
  while iptables -D FORWARD -o $i -j ACCEPT 2>/dev/null; do :; done
  while iptables -D FORWARD -i $i -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
  ip link del $i 2>/dev/null
done
for s in $EXTRA_SUBNETS; do ipset del UBIOS4local_network $s 2>/dev/null; done
sed -i '/AWGS_SHOWN/d;/alias awgs=/d;/alias awg-audit=/d;/alias awg-setup=/d' /root/.bashrc 2>/dev/null
rm -f /root/.hushlogin
[ -f $D/motd.orig ] && cp -a $D/motd.orig /etc/motd
if [ "$1" = --purge ]; then rm -rf $D; echo "Удалено всё, включая $D"; else echo "Службы и правила убраны. Файлы остались в $D (полностью: $0 --purge)"; fi
echo "Профиль VPN Client и правила Policy-Based Routes удалите в интерфейсе UniFi сами, если они больше не нужны."
EOF
chmod 755 /data/awg/awg-uninstall.sh
```

`/data/awg/awg-uninstall.sh` убирает службы, маршруты, правила iptables, интерфейсы и строки в `.bashrc`, возвращает баннер. С ключом `--purge` удаляет и `/data/awg` вместе с конфигами. Профиль-рельсу и правила PBR удалите в UniFi вручную, **сначала правила**: пока правило ссылается на рельсу без AWG-маршрута, его устройства остаются без интернета. На VPS: `systemctl disable --now awg-server; rm -rf /etc/amnezia /etc/systemd/system/awg-server.service /usr/local/bin/awg-up.sh`.

<a name="p12"></a>

## 12. Диагностика и проблемы

Всё ниже случилось на самом деле, пока собиралась эта схема. Таблица экономит часы: найдите свой симптом.

| Симптом                                                                                       | Причина                                                                      | Что делать                                                                                                                                                       |
|-----------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Handshake прошёл, 4–5 пингов, потом тишина в обе стороны через 5–8 с. Смена порта не помогает | DPI распознаёт WireGuard и рубит поток                                       | AmneziaWG вместо WireGuard. Подтвердить можно тестом ниже                                                                                                        |
| На сервере `tcpdump` пуст, роутер шлёт handshake по 148 байт                                  | Порт закрыт у хостера или в ufw, неверный IP или порт                        | Файрвол хостера, `ufw status`, Endpoint в конфиге                                                                                                                |
| Пакеты до сервера доходят, ответа (92 байта) нет                                              | Сервер не знает ключ клиента: peer не загружен или ключи перепутаны          | `awg show awg0` на сервере: peer с публичным ключом роутера и `allowed ips`. Через WireGuard-inbound 3x-ui так и было                                            |
| Handshake есть, ping через туннель не идёт, сайты открываются                                 | ICMP режется у оператора или в его цепочке                                   | Не поломка. Сторож проверяет по HTTPS                                                                                                                            |
| Handshake есть, трафика из интернета через свой VPS нет                                       | Нет `ip_forward` или NAT на сервере                                          | `/root/audit-server.sh`                                                                                                                                          |
| `awg setconf`: `Line unrecognized`                                                            | Бинарник не знает параметр конфига                                           | Свежая сборка или конфиг без новых параметров                                                                                                                    |
| Устройства под PBR без интернета                                                              | Сторож не работает, или в `awg.env` не та таблица/метка (профиль пересоздан) | `systemctl status awg-failover`, `tail /data/awg/failover.log`, `awgs` (часть 8); если профиль пересоздавали: `awg-detect.sh` и `systemctl restart awg-failover` |
| В туннель ушли и устройства вне PBR                                                           | Правило по подсети вместо метки (так выглядела наша первая версия)           | `ip rule show`: лишних правил с приоритетом меньше 32504 быть не должно; `awg-audit` (часть 9)                                                                   |
| Оба канала нестабильны, endpoint «прыгает»                                                    | Один ключ на двух устройствах                                                | Отдельный конфиг для роутера, старый клиент выключить                                                                                                            |
| Дубли правил NAT/FORWARD, третий процесс `amneziawg-go`                                       | Два экземпляра сторожа или старая служба                                     | `awg-audit` (часть 9) и его подсказки                                                                                                                            |
| Имитация сбоя правилом iptables «сама пропала»                                                | UniFi пересобирает свои цепочки                                              | Флаг `/tmp/awg-sim-down`                                                                                                                                         |
| После `wg-quick down/up` пропали маршруты                                                     | Интерфейс пересоздан, ядро удаляет привязанные к нему маршруты               | Сторож восстанавливает маршрут за 5 с                                                                                                                            |
| Скрипт сервера выполнился на роутере                                                          | Перепутали окно SSH                                                          | Смотрите на приглашение; серверные скрипты гайда на роутере не запускаются                                                                                       |
| Баннер UniFi не убирается настройкой sshd                                                     | Он печатается из `/etc/motd`                                                 | Шаг 8.3                                                                                                                                                          |
| После обновления прошивки нет панели и автозапуска                                            | Очищены `/etc` и `.bashrc`                                                   | `/data/awg/awg-restore.sh` (шаг 5.5)                                                                                                                             |
| Telegram: в логе 409 Conflict                                                                 | Тот же бот читается другой программой (например, 3x-ui)                      | Отдельный бот для роутера                                                                                                                                        |

<a name="hs"></a>

### Handshake не проходит: смотрим с двух сторон

Запустите одновременно и сравните: что ушло с роутера и что пришло на сервер.

**Роутер** · что уходит и приходит на WAN (сервер берётся из Endpoint конфига)

```bash
. /data/awg/awg.env
SRV=$(awk -F'[ =:]+' '/^Endpoint/{print $2; exit}' /data/awg/main.conf)   # для запасного: backup.conf
tcpdump -ni $WANIF udp and host $SRV
```

**VPS** · что доходит до сервера (только свой VPS)

```bash
tcpdump -ni any udp port 51823
```

Сервер провайдера изнутри вы не увидите, поэтому для него смотрите только сторону роутера: есть ли ответные пакеты.

| Роутер                                     | Сервер                     | Вывод                                                 |
|--------------------------------------------|----------------------------|-------------------------------------------------------|
| Исходящие есть, входящих нет               | пусто                      | Пакеты теряются по пути: файрвол хостера, порт, IP    |
| Исходящие есть                             | входящие есть, ответов нет | Ключи или peer на сервере                             |
| Обмен идёт, потом обрывается в обе стороны | то же                      | DPI. Тест ниже                                        |
| Исходящих нет                              | —                          | Маршрутизация на роутере: `ip route get 203.0.113.10` |

### Тест: режет ли провайдер WireGuard

Проверяем, живёт ли обычный двусторонний UDP-поток до сервера 40 секунд. Если он живёт, а настоящий WireGuard умирает за 5–8 секунд, причина в распознавании WireGuard, и нужна обфускация. На сервере временно откройте порт 5555 (`ufw allow 5555/udp`, если ufw включён, и у хостера).

**VPS** · эхо-сервер, остановка Ctrl+C

```bash
python3 - <<'EOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('0.0.0.0', 5555))
while True:
    d, a = s.recvfrom(2048)
    s.sendto(d, a)
EOF
```

**Роутер** · 40 пакетов по 128 байт, раз в секунду

```bash
python3 - <<'EOF'
import socket, os, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1)
ok = 0
for i in range(40):
    s.sendto(os.urandom(128), ('203.0.113.10', 5555))
    try:
        s.recvfrom(2048); ok += 1
    except socket.timeout:
        pass
    time.sleep(1)
print("ответов:", ok, "из 40")
EOF
```

> [!NOTE]
> **Как это было у нас**
>
> Обычный UDP: 40 из 40. UDP с поддельными заголовками WireGuard (тип 1, 2 и 4) тоже прошёл, 80 из 80. А настоящий WireGuard обрывался через 5–8 секунд на любом порту. Значит, DPI смотрит на настоящий handshake, а не на размеры и первые байты, и поддельный тест его не воспроизводит. Решающим оказался запуск настоящего AWG: он сразу дал 30 из 30 пингов и работал стабильно. После теста закройте порт: `ufw delete allow 5555/udp`.

<a name="p13"></a>

## 13. Справочник

### Файлы на роутере (`/data/awg`)

| Файл                                                                  | Назначение                                                                                      | Часть |
|-----------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|-------|
| `amneziawg-go`, `awg`                                                 | Бинарники AmneziaWG (aarch64)                                                                   | 1     |
| `awg-detect.sh`                                                       | Находит таблицу, метку и рельсу PBR, пишет `awg.env`                                            | 2     |
| `awg.env` 🔒                                                          | Все параметры установки                                                                         | 2     |
| `main.conf` 🔒, `backup.conf` 🔒                                      | Конфиги туннелей, содержат ключи                                                                | 4, 3  |
| `up.sh`                                                               | Поднять туннель(и): `up.sh [awgmain|awgbackup]`                                                 | 4     |
| `failover.sh`, `failover.log`                                         | Сторож и его журнал (~1000 строк)                                                               | 5     |
| `awg-failover.service`                                                | Копия юнита для восстановления                                                                  | 5     |
| `status.sh`                                                           | Панель `awgs`                                                                                   | 8     |
| `awg-motd.service`, `motd.orig`                                       | Очистка баннера, оригинал баннера                                                               | 8     |
| `audit.sh`                                                            | Аудит `awg-audit`                                                                               | 9     |
| `telegram.env` 🔒, `notify.sh`, `awg-notify.sh`, `awg-notify.service` | Уведомления; `notify.log`, `notify.spool`, `notify.events`, `notify.state` — их служебные файлы | 10    |
| `awg-restore.sh`                                                      | Восстановление автозапуска после обновления прошивки                                            | 5     |
| `awg-uninstall.sh`                                                    | Полное удаление                                                                                 | 11    |
| `install.sh`, `install.log`, `.installer`, `.panel`, `.audit`         | Установщик и его журнал; отметки компонентов, выбранных в установщике                           | ⚡    |

### Файлы на VPS

| Файл                                                                  | Назначение                                             |
|-----------------------------------------------------------------------|--------------------------------------------------------|
| `/etc/amnezia/server.conf` 🔒                                         | Ключ сервера, порт, параметры обфускации, peer роутера |
| `/usr/local/bin/awg-up.sh`                                            | Поднимает `awg0`, NAT, FORWARD                         |
| `/etc/systemd/system/awg-server.service`                              | Автозапуск                                             |
| `/etc/sysctl.d/99-awg.conf`                                           | `ip_forward=1`                                         |
| `/root/awg-server-build.sh`, `awg-server-setup.sh`, `audit-server.sh` | Сборка, установка, аудит                               |

### Параметры `awg.env`

| Параметр                           | Пример                                        | Смысл                                                         |
|------------------------------------|-----------------------------------------------|---------------------------------------------------------------|
| `TABLE`, `MARK`, `PRIO`, `RAIL_IF` | `178`, `0x6a0000/0x7e0000`, `32504`, `wgclt1` | Находит `awg-detect.sh`; руками не правятся                   |
| `WANIF`                            | `eth3`                                        | WAN-интерфейс для панели и диагностики                        |
| `MAIN`, `BACKUP`                   | `awgmain`, `awgbackup` или пусто              | Имена туннелей; пустой `BACKUP` означает режим одного туннеля |
| `RECOVER_SEC`                      | `600`                                         | Сколько основной должен работать без сбоев до возврата        |
| `EXTRA_SUBNETS`                    | `"192.168.3.0/24"`                            | Подсети VPN-сервера роутера для PBR                           |
| `VPS_IP`                           | `203.0.113.10`                                | Только для подсказок в панели                                 |

### Адреса и числа по умолчанию

| Что                               | Значение                                                                                        |
|-----------------------------------|-------------------------------------------------------------------------------------------------|
| Порт сервера AWG, подсеть, адреса | `51823/udp`, `10.0.1.0/24`: сервер `.1`, роутер `.2`                                            |
| MTU                               | из конфига; если там нет, то `1380` (запас под обфускацию). TCP MSS выравнивается автоматически |
| Метрики в таблице PBR             | активный туннель `5`, рельса UniFi `37`, `blackhole` `200`                                      |
| Проверка канала                   | HTTPS к `1.1.1.1` и `8.8.8.8`, потом ping; раз в 5 с; 3 сбоя                                    |
| Флаг имитации падения             | `/tmp/awg-sim-down` (исчезает при перезагрузке)                                                 |
| Рельса                            | `10.255.255.2/32` → `192.0.2.1:51820` (несуществующий узел)                                     |

### Шпаргалка

**Роутер** · самое нужное

```bash
awgs                          # панель;  awgs -s кратко;  awgs -i с внешними IP
awg-audit                     # аудит (только чтение)
tail -f /data/awg/failover.log
. /data/awg/awg.env; ip route show table $TABLE     # активный канал = metric 5
/data/awg/awg show awgmain
curl -s --interface awgmain https://ifconfig.me
touch /tmp/awg-sim-down       # имитация падения основного;  rm /tmp/awg-sim-down — отмена
/data/awg/up.sh awgmain       # применить новый main.conf
systemctl restart awg-failover
journalctl -t awg-failover -n 30 --no-pager
```

<a name="build"></a>

### Сборка бинарников для роутера самостоятельно

Если не хотите брать готовые файлы. Собирается на любом Linux x86_64 (например, на вашем VPS после шага 3.1, исходники уже лежат в `/root/awgbuild`). **Этот путь в нашей установке не проверялся**, мы использовали готовые бинарники; проверяйте результат командой из шага 1.2.

**VPS** · кросс-сборка под aarch64

```bash
apt-get install -y gcc-aarch64-linux-gnu
export PATH=$PATH:/snap/bin
cd /root/awgbuild/go/amneziawg-go-*/ && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /root/awgbuild/amneziawg-go-arm64 .
cd /root/awgbuild/tools/amneziawg-tools-*/src && make clean && make CC=aarch64-linux-gnu-gcc LDFLAGS=-static && cp wg /root/awgbuild/awg-arm64
make clean && make && install -m 755 wg /usr/local/bin/awg      # вернуть серверную сборку awg
file /root/awgbuild/*-arm64
```

**Роутер** · забрать на роутер

```bash
scp root@203.0.113.10:/root/awgbuild/amneziawg-go-arm64 /data/awg/amneziawg-go
scp root@203.0.113.10:/root/awgbuild/awg-arm64 /data/awg/awg
chmod 755 /data/awg/amneziawg-go /data/awg/awg; /data/awg/awg --version
```

Гайд собран по реальной установке на UniFi Dream Router 7 в октябре 2026 года. Адреса в примерах условные: `203.0.113.10` — ваш VPS, `198.51.100.20` — сервер провайдера. Интерфейс UniFi и пути в меню меняются от версии к версии; если пункт называется иначе, ищите по смыслу. Ubiquiti предупреждает, что изменения через CLI выходят за рамки штатной работы устройства: вы делаете это на свой риск, а `awg-uninstall.sh` убирает с роутера всё, что поставил этот гайд.

