# Codex Setup на headless-сервере

**Codex CLI — путь по умолчанию для Paperclip** в этом скилле. Проще Claude, безопаснее по policy.

## Почему `--device-auth`, а не обычный `codex login`

В Codex CLI 0.122+ две OAuth-команды:

| Команда | Что делает | Работает headless? |
|---|---|---|
| `codex login` | Запускает local HTTP server на `:1455`, ждёт OAuth redirect от `auth.openai.com/oauth/authorize` | **Нет** — сервер слушает на машине где запущен Codex, а браузер пользователя на маке этот порт не увидит |
| `codex login --device-auth` | Device-code flow: выводит URL + one-time code, polling'ом ждёт завершения | **Да** — браузер пользователя ходит на `auth.openai.com/codex/device`, вводит code, polling получает токен |

**Для любого серверного деплоя — `--device-auth`.** Сам Codex подсказывает это если запустить обычный `codex login`:

```
On a remote or headless machine? Use `codex login --device-auth` instead.
```

## Что важно знать про flow

После запуска `codex login --device-auth` CLI:

1. Получает от OpenAI **device code** (формат `XXXX-XXXXX`, например `WLX3-E0YGR`)
2. Печатает URL и code в stdout
3. **Polling'ом ходит** на `auth.openai.com/oauth/token` каждые N секунд с device code
4. Когда пользователь завершает авторизацию на `auth.openai.com/codex/device` — OpenAI отдаёт Codex токен
5. Токен сохраняется в `~/.codex/auth.json` (под тем пользователем от которого был запущен codex)
6. CLI выводит `Successfully logged in` и выходит с exit 0

**Важное отличие от Claude `setup-token`**: не нужно копировать authorization code обратно в терминал. Пользователь только открывает URL, вводит code, подтверждает. Дальше сервер всё делает сам.

## Почему всё равно нужна `script -qfec` обёртка

Хотя Codex не Ink-based (вывод простой text, не TUI), tmux-сессия всё равно может быть непредсказуемой — `script -qfec` гарантирует что:
- URL и device code сохраняются в лог-файл
- Лог остаётся даже если tmux убивается
- Можно дёрнуть code из лога если пользователь закрыл терминал

## Скрипт для автоматизации

```bash
tmux new-session -d -s clogin -x 600 -y 50 -- bash -c "
  script -qfec 'su - paperclip -c \"HTTPS_PROXY=http://127.0.0.1:1081 codex login --device-auth\"' /tmp/codex-login.log
"
sleep 8

# Извлечь URL
URL=$(cat /tmp/codex-login.log | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -oE 'https://auth\.openai\.com/codex/device' | head -1)

# Извлечь device code (формат XXXX-XXXXX)
CODE=$(cat /tmp/codex-login.log | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -oE '[A-Z0-9]{4}-[A-Z0-9]{5}' | head -1)
```

## Polling статуса от агента

После выдачи URL+code пользователю — агент может мониторить файл `/opt/paperclip/.codex/auth.json`:

```bash
for i in $(seq 1 60); do
    sleep 5
    if ssh root@<IP> "test -f /opt/paperclip/.codex/auth.json && su - paperclip -c 'codex login status' | grep -q 'Logged in'"; then
        echo "Авторизован"
        break
    fi
done
```

## Интеграция в Paperclip

В отличие от Claude (где токен в env-переменной `CLAUDE_CODE_OAUTH_TOKEN`), **Codex читает токен из файла** `~/.codex/auth.json`. Для Paperclip под пользователем `paperclip` это `/opt/paperclip/.codex/auth.json`. Никаких env-переменных для токена не нужно.

В systemd drop-in остаётся только прокси (для РФ-серверов):

```ini
# /etc/systemd/system/paperclip.service.d/env.conf
[Service]
Environment="HTTPS_PROXY=http://127.0.0.1:1081"
Environment="HTTP_PROXY=http://127.0.0.1:1081"
Environment="NO_PROXY=127.0.0.1,localhost,[::1]"
```

После `systemctl daemon-reload && systemctl restart paperclip` — Paperclip spawn'ит `codex`, Codex читает `auth.json`, ходит в `chatgpt.com/backend-api/codex/responses` через OAuth-токен под подпиской пользователя.

## Smoke-test

```bash
ssh root@<IP> "su - paperclip -c 'HTTPS_PROXY=http://127.0.0.1:1081 codex exec --skip-git-repo-check \"Reply only: PAPERCLIP_CODEX_OK\" < /dev/null'"
```

Ожидаем в выводе `PAPERCLIP_CODEX_OK`. Флаг `--skip-git-repo-check` важен — Codex по умолчанию хочет git-репо в cwd, иначе ругается. Для probe-команд это не нужно.

## Частые ошибки

### `warning: Codex could not find bubblewrap on PATH`

Не ошибка. Bubblewrap — sandbox Linux, на свежем Ubuntu нет. Codex использует vendored версию. Игнорировать.

### `codex login status` → `Not logged in`

Токен не сохранился. Проверить:
1. `ls /opt/paperclip/.codex/auth.json` — существует?
2. Права — владелец должен быть `paperclip:paperclip`
3. Смотреть `/tmp/codex-login.log` — не было ли ошибки при polling'е

### Paperclip adapter `codex_local` Test environment красный

Проверить:
1. `which codex` — должен быть `/usr/bin/codex`
2. `su - paperclip -c 'codex login status'` — должно быть `Logged in using ChatGPT`
3. `systemctl show paperclip --property=Environment | grep PROXY` — прокси должен быть в env для РФ-сервера
4. Проверить прямо `su - paperclip -c 'HTTPS_PROXY=... codex exec ...'`

### `codex exec` падает с timeout

Иногда при первом запуске Codex долго подтягивает модель. Увеличить `--timeout 120` или дать ему время — второй запуск обычно быстрее.

## Cleanup / re-login

Если нужно переавторизоваться:

```bash
ssh root@<IP> "
    rm -rf /opt/paperclip/.codex/auth.json
    su - paperclip -c 'codex logout' 2>/dev/null
"
# заново запустить codex_setup.sh
```

## Когда НЕ брать Codex вместо Claude

- У пользователя Claude Max ($200/мес) который **уже оплачен** и нет ChatGPT Plus → брать Claude (7B) чтобы не платить за вторую подписку
- Нужна именно Opus / Sonnet архитектура (код-задачи где Claude лучше GPT-5 / Codex-mini) → Claude через API-ключ (7C)
- Production-критичная система → API-ключ OpenAI или Anthropic напрямую (7C), не подписка вообще
