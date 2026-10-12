#!/usr/bin/env python3
# awg-bot — управление AmneziaWG на роутере из Telegram: статус, отчёт, переключение и остановка каналов.
#   python3 /data/awg/bot.py          служба (awg-bot.service)
#   python3 /data/awg/bot.py menu     прислать меню в чат и выйти (проверка)
#
# Один бот может обслуживать несколько роутеров в одном чате. Каждый роутер опрашивает Telegram сам
# (короткий опрос раз в ~2 с, без «съедания» свежих обновлений), кнопки несут имя роутера, и на кнопку
# отвечает только тот роутер, чьё имя в ней. Команды текстом: /status — ответят все роутеры,
# /status DR7 — только DR7. Команды-действия (/main, /backup, /auto, /stop) переспрашивают кнопкой.
#
# Слушает только чат TG_CHAT из telegram.env. Токен не попадает в список процессов (передаётся curl через stdin).
# Управление сторожем — через файл /data/awg/control (MODE, OFF_ACTION, DISABLED), сторож читает его каждые 5 с.
import json
import os
import random
import re
import socket
import subprocess
import sys
import threading
import time

DD = os.environ.get('DD', '/data/awg')
CTL = os.path.join(DD, 'control')
LOGF = os.path.join(DD, 'bot.log')
TGENV = os.path.join(DD, 'telegram.env')


def envfile(path):
    d = {}
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line.rstrip('\n'))
                if m:
                    v = m.group(2).strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                        v = v[1:-1]
                    d[m.group(1)] = v
    except OSError:
        pass
    return d


TG = envfile(TGENV)
AW = envfile(os.path.join(DD, 'awg.env'))
TOKEN = TG.get('TG_TOKEN', '')
CHAT = str(TG.get('TG_CHAT', ''))
MAIN = AW.get('MAIN') or 'awgmain'
BACKUP = AW.get('BACKUP', '')
TUNS = [t for t in (MAIN, BACKUP) if t]
NAME = TG.get('ROUTER_NAME') or socket.gethostname()
TAG = re.sub(r'[^\w]+', '_', NAME, flags=re.UNICODE).strip('_') or 'router'
IFACES = TUNS + ([] if TG.get('TG_NO_WAN') == '1' else [''])
_good = {'i': None}


def log(msg):
    try:
        line = time.strftime('%F %T ') + msg + '\n'
        with open(LOGF, 'a', encoding='utf-8') as f:
            f.write(line)
        if os.path.getsize(LOGF) > 200000:
            with open(LOGF, encoding='utf-8') as f:
                tail = f.readlines()[-500:]
            with open(LOGF, 'w', encoding='utf-8') as f:
                f.writelines(tail)
    except OSError:
        pass


def api(method, params=None, timeout=12):
    """Вызов Bot API через curl: сначала канал, который сработал в прошлый раз, потом остальные."""
    order = ([_good['i']] if _good['i'] in IFACES else []) + [i for i in IFACES if i != _good['i']]
    args_tail = []
    for k, v in (params or {}).items():
        if isinstance(v, (dict, list)):
            v = json.dumps(v, ensure_ascii=False)
        args_tail += ['--data-urlencode', '%s=%s' % (k, v)]
    for i in order:
        cmd = ['curl', '-4', '-s', '-m', str(timeout), '-K', '-', '-w', '\n%{http_code}']
        if i:
            cmd += ['--interface', i]
        try:
            p = subprocess.run(cmd + args_tail, input='url = "https://api.telegram.org/bot%s/%s"\n' % (TOKEN, method),
                               capture_output=True, text=True, timeout=timeout + 5)
        except (subprocess.TimeoutExpired, OSError):
            continue
        body, _, code = p.stdout.rpartition('\n')
        if code == '409':
            return {'ok': False, 'error_code': 409}
        if code in ('', '000'):
            continue
        _good['i'] = i
        try:
            return json.loads(body)
        except ValueError:
            return {'ok': False, 'error_code': int(code) if code.isdigit() else 0}
    return None


def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def header():
    return '🛜 <b>#%s</b>\n' % esc(TAG)


def sh(*args, timeout=60):
    try:
        return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout).stdout
    except (subprocess.TimeoutExpired, OSError) as e:
        return 'ошибка: %s' % e


def notify_text(kind):
    return sh(os.path.join(DD, 'awg-notify.sh'), 'text', kind, timeout=120).strip() or '<i>нет данных</i>'


# ---------- управление сторожем ----------
def ctl_read():
    c = envfile(CTL)
    mode = c.get('MODE', 'auto')
    if mode not in ('auto', 'main', 'backup', 'off'):
        mode = 'auto'
    off = c.get('OFF_ACTION', 'block')
    dis = [x for x in c.get('DISABLED', '').split() if x in TUNS]
    return mode, off, dis


def ctl_write(mode, off, dis):
    tmp = CTL + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write('# пишет бот Telegram (awg-bot); читает сторож failover.sh каждые 5 с\n')
        f.write('MODE=%s\nOFF_ACTION=%s\nDISABLED="%s"\n' % (mode, off, ' '.join(dis)))
    os.replace(tmp, CTL)
    log('control: MODE=%s OFF_ACTION=%s DISABLED=%s' % (mode, off, ' '.join(dis)))


def active():
    out = sh('ip', 'route', 'show', 'table', AW.get('TABLE', '0'), timeout=10)
    for line in out.splitlines():
        m = re.match(r'default dev (\S+)', line)
        if m and m.group(1) in TUNS:
            return m.group(1)
    return None


def wait_applied(check, sec=15):
    for _ in range(sec * 2):
        if check():
            return True
        time.sleep(0.5)
    return False


def report_time():
    return envfile(TGENV).get('REPORT_TIME', '0900')


def set_report_time(v):
    lines = []
    try:
        with open(TGENV, encoding='utf-8') as f:
            lines = [ln for ln in f if not ln.startswith('REPORT_TIME=')]
    except OSError:
        pass
    lines.append('REPORT_TIME=%s\n' % v)
    tmp = TGENV + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.writelines(lines)
    os.chmod(tmp, 0o600)
    os.replace(tmp, TGENV)
    log('REPORT_TIME=%s' % v)


def rt_label(v):
    return 'по запросу' if v == 'off' else '%s:%s' % (v[:2], v[2:])


# ---------- кнопки ----------
def b(text, action):
    return {'text': text, 'callback_data': ('%s|%s' % (TAG, action))[:64]}


def menu_kb():
    mode, off, dis = ctl_read()
    mk = lambda m: '✓ ' if mode == m else ''
    rows = [
        [b('ℹ️ Статус', 'status'), b('📊 Отчёт', 'report')],
        [b(mk('main') + '🟢 Основной', 'mode:main')] + ([b(mk('backup') + '🟡 Запасной', 'mode:backup')] if BACKUP else []) + [b(mk('auto') + '🤖 Авто', 'mode:auto')],
        [b('⏹ Остановить…', 'stopask'), b('▶️ Запустить всё', 'start')],
        [b('📜 Журнал', 'log'), b('🌐 IP', 'ip'), b('🩺 Аудит', 'check')],
        [b('⏰ Отчёт: ' + rt_label(report_time()), 'rt')],
    ]
    return {'inline_keyboard': rows}


def back_kb():
    return {'inline_keyboard': [[b('☰ Меню', 'menu'), b('ℹ️ Статус', 'status')]]}


def send(text, kb=None):
    p = {'chat_id': CHAT, 'text': header() + text, 'parse_mode': 'HTML', 'disable_web_page_preview': 'true'}
    if kb:
        p['reply_markup'] = kb
    r = api('sendMessage', p)
    if not r or not r.get('ok'):
        log('sendMessage не удалось: %s' % (r and r.get('description') or 'нет связи'))


def mode_line():
    mode, off, dis = ctl_read()
    t = {'auto': '🤖 авто', 'main': '🟢 вручную: держать %s' % MAIN, 'backup': '🟡 вручную: держать %s' % BACKUP,
         'off': '⛔ каналы остановлены, PBR %s' % ('через провайдера' if off == 'wan' else 'заблокирован')}[mode]
    if dis:
        t += '; ⏸ остановлены: ' + ', '.join(dis)
    return 'Режим: ' + t


# ---------- действия ----------
def do_info(kind):
    titles = {'status': 'ℹ️ Статус', 'report': '📊 Отчёт по запросу', 'log': '📜 Журнал сторожа',
              'ip': '🌐 Внешние IP', 'check': '🩺 Аудит'}
    if kind in ('check', 'ip', 'report'):
        send('<i>%s: собираю…</i>' % titles[kind])
    send('<b>%s</b> · %s\n%s' % (titles[kind], time.strftime('%F %H:%M'), notify_text(kind)), back_kb())


def do_mode(m):
    mode, off, dis = ctl_read()
    if m == 'backup' and not BACKUP:
        return send('Запасного канала нет.', back_kb())
    want = MAIN if m == 'main' else BACKUP if m == 'backup' else None
    if want and want in dis:
        dis = [x for x in dis if x != want]
    ctl_write(m, off, dis)
    if want:
        ok = wait_applied(lambda: active() == want)
        txt = ('Переключено на <b>%s</b>. Держу его, пока он жив; при сбое сторож всё равно уйдёт на другой канал. '
               'Вернуть автоматику — «🤖 Авто».' % want) if ok else (
               'Режим «держать %s» включён, но канал не прошёл проверку: трафик остаётся на %s.' % (want, active() or 'blackhole'))
    else:
        wait_applied(lambda: active() is not None, 10)
        txt = 'Автоматический режим: основной %s, при сбое — запасной, возврат после стабильной работы.' % MAIN
    send(txt + '\n' + notify_text('status'), menu_kb())


def do_stopask():
    rows = [[b('⛔ Все каналы: блокировать PBR', 'stop:block')],
            [b('🌐 Все каналы: PBR через провайдера', 'stop:wan')]]
    for t in TUNS:
        rows.append([b('⏸ Только %s' % t, 'dis:%s' % t)])
    rows.append([b('✖ Отмена', 'menu')])
    send('<b>Что остановить?</b>\n'
         '⛔ — туннели выключаются, устройства под правилами PBR остаются без интернета (утечки нет).\n'
         '🌐 — туннели выключаются, устройства под правилами ходят напрямую через провайдера.\n'
         '⏸ — останавливается один канал, трафик идёт через другой.', {'inline_keyboard': rows})


def do_stop(how):
    mode, off, dis = ctl_read()
    ctl_write('off', how, dis)
    wait_applied(lambda: active() is None, 12)
    send('⏹ Каналы остановлены: PBR-трафик %s.\nЗапустить снова — «▶️ Запустить всё».\n%s' % (
        'идёт через провайдера' if how == 'wan' else 'заблокирован', notify_text('status')), menu_kb())


def do_disable(t):
    mode, off, dis = ctl_read()
    if t not in TUNS:
        return
    if t not in dis:
        dis.append(t)
    if mode == ('main' if t == MAIN else 'backup'):
        mode = 'auto'
    ctl_write(mode, off, dis)
    left = [x for x in TUNS if x not in dis]
    wait_applied(lambda: active() in left if left else active() is None, 15)
    extra = '' if left else ' Других каналов нет: PBR-трафик %s.' % ('идёт через провайдера' if off == 'wan' else 'заблокирован')
    send('⏸ Канал <b>%s</b> остановлен.%s\n%s' % (t, extra, notify_text('status')), menu_kb())


def do_start():
    mode, off, dis = ctl_read()
    ctl_write('auto' if mode == 'off' else mode, off, [])
    wait_applied(lambda: active() is not None, 40)
    send('▶️ Каналы запущены.\n' + notify_text('status'), menu_kb())


def do_rt_menu():
    rows = [[b('Только по запросу', 'rt:off')],
            [b('07:00', 'rt:0700'), b('08:00', 'rt:0800'), b('09:00', 'rt:0900')],
            [b('12:00', 'rt:1200'), b('18:00', 'rt:1800'), b('21:00', 'rt:2100')],
            [b('✖ Отмена', 'menu')]]
    send('<b>⏰ Суточный отчёт</b>\nСейчас: %s. Другое время — командой <code>/reporttime 0930 %s</code>.' % (
        rt_label(report_time()), esc(TAG)), {'inline_keyboard': rows})


def do_rt(v):
    if v != 'off' and not re.match(r'^([01]\d|2[0-3])[0-5]\d$', v):
        return send('Время — в виде ЧЧММ, например 0930, или off.', back_kb())
    set_report_time(v)
    send('⏰ Суточный отчёт: <b>%s</b>.%s' % (rt_label(v), ' Получить отчёт можно кнопкой «📊 Отчёт».' if v == 'off' else ''), menu_kb())


def do_menu():
    send('<b>Управление</b> · ' + esc(mode_line()) + '\nАктивный канал: <b>%s</b>' % (active() or 'нет'), menu_kb())


def do_confirm(action):
    names = {'mode:main': 'держать основной %s' % MAIN, 'mode:backup': 'держать запасной %s' % BACKUP,
             'mode:auto': 'автоматический режим', 'stopask': 'остановку каналов', 'start': 'запуск всех каналов'}
    send('Применить %s на этом роутере?' % names.get(action, action),
         {'inline_keyboard': [[b('✅ Да', action), b('✖ Нет', 'menu')]]})


ACTIONS = {'status': lambda: do_info('status'), 'report': lambda: do_info('report'), 'log': lambda: do_info('log'),
           'ip': lambda: do_info('ip'), 'check': lambda: do_info('check'), 'menu': do_menu, 'stopask': do_stopask,
           'start': do_start, 'rt': do_rt_menu}


def run_action(a):
    try:
        if a in ACTIONS:
            ACTIONS[a]()
        elif a.startswith('mode:'):
            do_mode(a[5:])
        elif a.startswith('stop:'):
            do_stop('wan' if a[5:] == 'wan' else 'block')
        elif a.startswith('dis:'):
            do_disable(a[4:])
        elif a.startswith('rt:'):
            do_rt(a[3:])
    except Exception as e:  # бот не должен падать из-за одной команды
        log('ошибка в %s: %r' % (a, e))
        send('Ошибка при выполнении: <code>%s</code>' % esc(repr(e)[:300]), back_kb())


def bg(a):
    threading.Thread(target=run_action, args=(a,), daemon=True).start()


# ---------- разбор обновлений ----------
INFO_CMDS = {'status', 'report', 'log', 'ip', 'check', 'menu'}
ACT_CMDS = {'main': 'mode:main', 'backup': 'mode:backup', 'auto': 'mode:auto', 'stop': 'stopask', 'start_all': 'start'}


def handle_message(m):
    if str(m.get('chat', {}).get('id')) != CHAT:
        return
    text = (m.get('text') or '').strip()
    if not text.startswith('/'):
        return
    parts = text.split()
    cmd = parts[0][1:].split('@')[0].lower()
    args = parts[1:]
    targets = [a.lstrip('#') for a in args if not re.match(r'^(\d{4}|off)$', a)]
    if targets and not any(t.lower() in (TAG.lower(), 'all', 'все') for t in targets):
        return   # команда другому роутеру
    if cmd in ('start', 'help'):
        cmd = 'menu'
    if cmd in INFO_CMDS:
        bg(cmd)
    elif cmd in ACT_CMDS:
        if targets:
            bg(ACT_CMDS[cmd])
        else:
            do_confirm(ACT_CMDS[cmd])
    elif cmd == 'reporttime':
        v = next((a for a in args if re.match(r'^(\d{4}|off)$', a)), '')
        bg('rt:' + v if v else 'rt')


def handle_callback(c):
    data = c.get('data') or ''
    tag, _, action = data.partition('|')
    if tag != TAG:
        return   # кнопка другого роутера
    if str(c.get('message', {}).get('chat', {}).get('id')) != CHAT:
        return
    api('answerCallbackQuery', {'callback_query_id': c.get('id'), 'text': 'принято'})
    bg(action)


def set_commands():
    cmds = [('menu', 'меню с кнопками'), ('status', 'состояние каналов'), ('report', 'отчёт сейчас'),
            ('log', 'журнал сторожа'), ('ip', 'внешние IP'), ('check', 'аудит установки'),
            ('main', 'держать основной канал'), ('backup', 'держать запасной канал'), ('auto', 'автоматический режим'),
            ('stop', 'остановить каналы'), ('start_all', 'запустить все каналы'), ('reporttime', 'время суточного отчёта')]
    api('setMyCommands', {'commands': [{'command': a, 'description': d} for a, d in cmds]})


def main():
    if not TOKEN or not CHAT:
        print('нет TG_TOKEN/TG_CHAT в %s' % TGENV)
        sys.exit(2)
    if len(sys.argv) > 1 and sys.argv[1] == 'menu':
        do_menu()
        return
    log('старт: роутер #%s, чат %s' % (TAG, CHAT))
    # всё, что пришло до старта, пропускаем
    last = 0
    for _ in range(10):
        r = api('getUpdates', {'timeout': 0})
        if r and r.get('ok'):
            last = max([u['update_id'] for u in r['result']] or [0])
            break
        time.sleep(3 + random.random() * 3)
    set_commands()
    seen = {}           # update_id → когда впервые увидели; подтверждаем Telegram только старые (>10 мин),
    last_prune = 0      # чтобы другие роутеры с этим же ботом успели их прочитать
    while True:
        r = api('getUpdates', {'timeout': 0, 'allowed_updates': ['message', 'callback_query']})
        now = time.time()
        if r is None:
            time.sleep(10)
            continue
        if r.get('error_code') == 409:     # вебхук или одновременный опрос с другого роутера
            time.sleep(0.5 + random.random())
            continue
        for u in sorted(r.get('result', []), key=lambda x: x['update_id']):
            uid = u['update_id']
            seen.setdefault(uid, now)
            if uid <= last:
                continue
            last = uid
            try:
                if 'message' in u:
                    handle_message(u['message'])
                elif 'callback_query' in u:
                    handle_callback(u['callback_query'])
            except Exception as e:
                log('ошибка обработки %s: %r' % (uid, e))
        if now - last_prune > 60:
            old = [k for k, t in seen.items() if now - t > 600]
            if old:
                api('getUpdates', {'offset': max(old) + 1, 'timeout': 0, 'limit': 1})
                for k in old:
                    seen.pop(k, None)
            last_prune = now
        time.sleep(2 + random.random() * 0.6)


if __name__ == '__main__':
    main()
