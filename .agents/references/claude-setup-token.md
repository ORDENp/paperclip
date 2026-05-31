# Claude Setup Token на headless-сервере

**Критичный файл.** Каждый нюанс здесь — цена одного потерянного часа на 2026-04-22.

## Почему `setup-token`, а не `auth login`

В Claude Code v2.1+ есть две OAuth-команды:

| Команда | Для чего | Где токен | Работает headless? |
|---|---|---|---|
| `claude auth login` | Интерактивный login на локальном маке | macOS Keychain или `~/.claude/` | **Нет** — Ink TUI висит в tmux после submit code, token не попадает в keychain, auth_status = false |
| `claude setup-token` | CI/headless, specifically for servers | Печатает в stdout → пользователь сам кладёт куда надо | **Да**, но с обёрткой `script -qfec` |

Для Paperclip-деплоя **всегда** `setup-token`.

## Почему `script -qfec`

Claude Code 2.1 использует [Ink](https://github.com/vadimdemedes/ink) — React-based TUI. Поведение:

1. Пользователь вставляет code в input
2. Claude делает POST к Anthropic `oauth/token` endpoint
3. Получает long-lived `sk-ant-oat01-...` токен
4. **Печатает токен в TUI буфер**
5. **Мгновенно выходит** (exit 0)

Между шагами 4 и 5 — миллисекунды. Если смотреть `tmux capture-pane` — не успеешь прочитать. Если считывать через `&& echo $(cat ...)` — tmux уже мёртв.

Решение: обернуть весь `setup-token` в `script -qfec` — это эмулятор pty, который пишет **весь вывод pty в файл** параллельно с отображением. После exit — файл остаётся, оттуда grep-аем токен.

```bash
script -qfec 'su - paperclip -c "claude setup-token"' /tmp/claude-login.log
```

Флаги:
- `-q` — quiet (не печатать «Script started/done»)
- `-f` — flush на каждой записи (важно — без него буфер может не сбросится до crash)
- `-e` — сохранить exit code внутренней команды
- `-c <cmd>` — команда вместо интерактивного shell

## Обязательно широкое окно tmux

Ink рендерит URL с word-wrap по COLUMNS текущего pty. На 80 колонок URL переносится на 3-5 строк, и `grep -oE 'https://...'` возвращает только первую строку.

Запускай tmux с `-x 600` и передавай `COLUMNS=600` в env:

```bash
tmux new-session -d -s clogin -x 600 -y 50 -- bash -c "script -qfec 'su - paperclip -c \"COLUMNS=600 claude setup-token\"' /tmp/claude-login.log"
```

## Как вытащить URL из лог-файла

```bash
cat /tmp/claude-login.log \
  | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \    # снять ANSI escape codes
  | tr -d '\r\n' \                         # склеить многострочный URL
  | grep -oE 'https://claude\.com/cai/oauth/authorize[a-zA-Z0-9?=&_+%.:\/-]+' \
  | head -1
```

В хвосте URL иногда прилипает `Pastecodehereifprompted` (это надпись Ink под полем ввода, grep зацепил потому что `trim-newlines` склеил всё). Отрезать:

```bash
URL="${URL%Pastecodehereifprompted}"
```

## Как инжектить code в tmux

```bash
tmux send-keys -t clogin -l "$CODE"   # -l = literal, не интерпретировать как keyname
sleep 1
tmux send-keys -t clogin Enter
```

Между `-l` и `Enter` нужен sleep — Ink ReactCLI иногда не успевает зарегистрировать input, и Enter прилетает в пустое поле.

## Как вытащить токен после submit

```bash
sleep 10   # ждём пока Claude сходит в Anthropic и получит токен

cat /tmp/claude-login.log \
  | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
  | tr -d '\r\n' \
  | grep -oE 'sk-ant-oat01-[a-zA-Z0-9_-]+' \
  | head -1
```

Токен выглядит так: `sk-ant-oat01-xxxxxxxxxxxxxxxx-yyyyyyyyyy-zzzzzzz` (длина ~130 символов). Видимость — ровно один раз в TUI, дальше только из файла.

## Где хранить токен

1. **На сервере в systemd drop-in** — для Paperclip runtime:
   ```ini
   # /etc/systemd/system/paperclip.service.d/env.conf
   [Service]
   Environment="CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-..."
   ```
   `chmod 600`, `systemctl daemon-reload && systemctl restart paperclip`.

2. **В локальном .env пользователя (CyberOS-style)** — master copy на случай если сервер пересоздастся:
   ```
   CLAUDE_OAUTH_TOKEN_PAPERCLIP_<server-name>='sk-ant-oat01-...'  # TTL 1 год (до YYYY-MM-DD)
   ```

Claude Code СLI читает токен в таком порядке (убывание приоритета):
1. `CLAUDE_CODE_OAUTH_TOKEN` env variable
2. `ANTHROPIC_API_KEY` env variable (это API-ключ, не OAuth, даёт другое поведение)
3. `~/.claude.json` / keychain

В Paperclip через systemd env → пункт 1, сразу подхватывается.

## Частые ошибки

### OAuth error: Request failed with status code 403

Причина: запрос к `api.anthropic.com/oauth/token` идёт с заблокированного IP (РФ), **или** прокси не настроен в env процесса claude.

Проверка:
```bash
# С сервера
curl -sI https://api.anthropic.com                          # прямой
curl -sI -x http://127.0.0.1:1081 https://api.anthropic.com # через прокси
```

Прямой должен быть 403 (для РФ IP), через прокси — **не 403** (404 или 301 — нормально, главное не 403).

Если прокси не помогает — сервер прокси тоже в блок-листе (бывает). Попробовать другой VPN-выход или зарубежный сервер.

### Invalid code / code already used

OAuth code — **одноразовый** и привязан к `code_challenge` конкретного запуска. Если:
- Запустил `setup-token` → получил URL A → пользователь открыл
- Перезапустил `setup-token` → получил URL B
- Пользователь авторизовался по URL A, code из URL A

То submit code из URL A в процесс URL B → Invalid. Значит перезапустил — отдавай пользователю **новый** URL.

### Токен есть, но Paperclip Test environment красный

```
ANTHROPIC_API_KEY is not set; subscription-based auth can be used if Claude is logged in.
```

Это **не ошибка**, это INFO. Зелёный indicator — когда есть `Claude hello probe succeeded. (Hello!)` в конце.

Если именно hello probe красный:
1. `systemctl show paperclip | grep Environment` — убедиться что `CLAUDE_CODE_OAUTH_TOKEN` реально в env процесса
2. `su - paperclip -c 'env | grep CLAUDE'` — не то же самое (не наследует от systemd), не показатель
3. Проверить непосредственно:
   ```bash
   su - paperclip -c 'HTTPS_PROXY=http://127.0.0.1:1081 CLAUDE_CODE_OAUTH_TOKEN=<token> claude --print "hi" < /dev/null'
   ```
   Если ответ есть — проблема в systemd env, не в токене. Проверить синтаксис drop-in файла.

## Cleanup

Для отладки можно убить текущую сессию и начать заново:

```bash
ssh root@<IP> "
    tmux kill-server 2>/dev/null
    pkill -9 claude 2>/dev/null
    rm -f /tmp/claude-login.log
"
```
