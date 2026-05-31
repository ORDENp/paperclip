#!/usr/bin/env bash
# Headless OAuth для Claude Code CLI под подпиской Claude Max / Pro.
#
# Двухфазный запуск (отдельно от tmux потому что нужен user interaction):
#   1. bash claude_setup_token.sh <IP> init
#      → печатает OAuth URL, пользователь открывает в Chrome под своей Claude Max
#   2. bash claude_setup_token.sh <IP> submit '<code>'
#      → инжектит code, вытаскивает token, пишет в systemd override
#
# Почему через `script -qfec`: Claude Code setup-token на Ink TUI мгновенно
# крешит сессию после выдачи токена. Без записи pty в файл токен (виден 1 раз)
# теряется навсегда. Подробности — references/claude-setup-token.md.
#
# Внутри проксируем всё через 127.0.0.1:1081 (если Phase 5 была) —
# иначе OAuth падает на 403 от api.anthropic.com для РФ IP.

set -euo pipefail

IP="${1:?Usage: $0 <IP> init | $0 <IP> submit '<code>'}"
MODE="${2:?init | submit}"

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP"
LOG=/tmp/claude-login.log

case "$MODE" in
init)
    echo "📦 Устанавливаю @anthropic-ai/claude-code на $IP..."
    $SSH "command -v claude >/dev/null || npm install -g @anthropic-ai/claude-code"
    $SSH "claude --version"

    # Детектим наличие sslocal — если есть, прокси нужен
    PROXY_ENV=""
    if $SSH "systemctl is-active sslocal" >/dev/null 2>&1; then
        PROXY_ENV="HTTPS_PROXY=http://127.0.0.1:1081 HTTP_PROXY=http://127.0.0.1:1081 NO_PROXY=127.0.0.1,localhost"
        echo "   sslocal active → подключу через NL-прокси"
    fi

    echo "🚀 Запускаю claude setup-token в tmux+script (ширина 600, чтобы URL не обрывался)..."
    $SSH "
        pkill -9 claude 2>/dev/null; sleep 1
        tmux kill-session -t clogin 2>/dev/null || true
        rm -f $LOG
        tmux new-session -d -s clogin -x 600 -y 50 -- bash -c \"
            script -qfec 'su - paperclip -c \\\"$PROXY_ENV COLUMNS=600 claude setup-token\\\"' $LOG
        \"
        sleep 7
    "

    # Извлекаем URL (grep из лог-файла, Ink wrapping убираем tr -d \\n)
    URL=$($SSH "cat $LOG 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r\n' | grep -oE 'https://claude\.com/cai/oauth/authorize[a-zA-Z0-9?=&_+%.:\/-]+' | head -1")

    if [[ -z "$URL" ]]; then
        echo "❌ URL не появился в логе. Проверь:" >&2
        $SSH "cat $LOG | tail -30"
        exit 1
    fi

    # Отрезаем хвост от "Pastecodehereifprompted" если grep зацепил
    URL="${URL%Pastecodehereifprompted}"
    # Извлекаем state — он конец URL после &state=
    STATE=$(echo "$URL" | grep -oE 'state=[a-zA-Z0-9_-]+' | head -1 | cut -d= -f2)

    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "✅ OAuth URL готов. Открой в Chrome (там где залогинен в Claude Max):"
    echo
    echo "$URL"
    echo
    echo "После Authorize на claude.com → platform.claude.com покажет code."
    echo "Код будет заканчиваться на:  #$STATE"
    echo
    echo "Когда получишь code — запусти:"
    echo "   bash $0 $IP submit '<code>'"
    echo "════════════════════════════════════════════════════════════════"
    ;;

submit)
    CODE="${3:?Usage: $0 $IP submit '<code>'}"

    echo "📨 Инжектирую code в tmux сессию clogin..."
    $SSH "
        tmux send-keys -t clogin -l '$CODE'
        sleep 1
        tmux send-keys -t clogin Enter
        sleep 10
    "

    echo "🔍 Вытаскиваю long-lived OAuth token из $LOG..."
    TOKEN=$($SSH "cat $LOG 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r\n' | grep -oE 'sk-ant-oat01-[a-zA-Z0-9_-]+' | head -1")

    if [[ -z "$TOKEN" ]]; then
        echo "❌ Токен не найден. Проверь лог:" >&2
        $SSH "sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' $LOG | tail -30"
        echo
        echo "Если видишь 'OAuth error 403' — прокси не работает (Phase 5 надо переделать)."
        echo "Если 'Invalid code' — code истёк или state не совпал, запусти init заново."
        exit 1
    fi

    echo "   Токен получен: ${TOKEN:0:30}...${TOKEN: -10}"

    # Определяем нужен ли proxy
    PROXY_ENV=""
    if $SSH "systemctl is-active sslocal" >/dev/null 2>&1; then
        PROXY_ENV='Environment="HTTPS_PROXY=http://127.0.0.1:1081"
Environment="HTTP_PROXY=http://127.0.0.1:1081"
Environment="NO_PROXY=127.0.0.1,localhost,[::1]"'
    fi

    echo "⚙️  Пишу /etc/systemd/system/paperclip.service.d/env.conf..."
    $SSH "
        mkdir -p /etc/systemd/system/paperclip.service.d
        cat > /etc/systemd/system/paperclip.service.d/env.conf <<EOF
[Service]
$PROXY_ENV
Environment=\"CLAUDE_CODE_OAUTH_TOKEN=$TOKEN\"
EOF
        chmod 600 /etc/systemd/system/paperclip.service.d/env.conf
        systemctl daemon-reload
        systemctl restart paperclip
        sleep 5
        systemctl is-active paperclip
    "

    echo "🧪 Smoke-test под paperclip user..."
    $SSH "su - paperclip -c 'HTTPS_PROXY=http://127.0.0.1:1081 HTTP_PROXY=http://127.0.0.1:1081 CLAUDE_CODE_OAUTH_TOKEN=$TOKEN claude --print --model sonnet \"Reply only with: PAPERCLIP_AUTH_OK\" < /dev/null' 2>&1 | tail -3"

    # Пишем в локальный .env (master copy)
    if [[ -f .env ]]; then
        SERVER_NAME=$(basename "$(pwd)")
        LINE="CLAUDE_OAUTH_TOKEN_PAPERCLIP_${SERVER_NAME}='$TOKEN'  # Claude Max OAuth на $IP, TTL 1 год"
        grep -v "^CLAUDE_OAUTH_TOKEN_PAPERCLIP_${SERVER_NAME}=" .env > .env.tmp 2>/dev/null || true
        mv .env.tmp .env 2>/dev/null || true
        echo "$LINE" >> .env
        echo "   Токен сохранён в .env как CLAUDE_OAUTH_TOKEN_PAPERCLIP_${SERVER_NAME}"
    fi

    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "✅ Claude Max подписка подключена к Paperclip."
    echo "   Дальше: в Paperclip UI (http://$IP/<company>/agents/ceo/configuration)"
    echo "   → Adapter: Claude Code (local) → Test environment → должно быть Passed"
    echo "════════════════════════════════════════════════════════════════"
    ;;

*)
    echo "Usage: $0 <IP> init | $0 <IP> submit '<code>'" >&2
    exit 1
    ;;
esac
