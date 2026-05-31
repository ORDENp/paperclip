#!/usr/bin/env bash
# Headless OAuth для Claude Code CLI под подпиской Claude Max / Pro.
# ⚠️ РИСК: Anthropic банит подписки в оркестраторах. Для prod лучше API-ключ.
#
# Usage:
#   bash claude_setup.sh <IP> <root_password> init         # Phase 1 — получить URL+code
#   bash claude_setup.sh <IP> <root_password> submit CODE  # Phase 2 — сдать authorization code
#
# Отличие от Codex: у Claude двухфазный OAuth (authorization code flow, не device),
# пользователь должен скопировать код ИЗ браузера и прислать обратно.

set -euo pipefail

IP="${1:?IP первым аргументом}"
PASS="${2:?root пароль вторым аргументом}"
PHASE="${3:?init или submit третьим аргументом}"
CODE="${4:-}"

SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"

if [ "$PHASE" = "init" ]; then
  # Phase 1 — запустить setup-token, вытащить URL
  $SSH "root@$IP" bash <<'REMOTE'
set -uo pipefail
# Установка Claude CLI если нужно
if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code 2>&1 | tail -3
fi
echo "claude версия: $(claude --version 2>/dev/null || echo installed)"

# Убиваем старые попытки
pkill -u paperclip -f 'claude setup-token' 2>/dev/null || true
tmux kill-session -t claude-login 2>/dev/null || true
rm -f /tmp/claude-login.log
touch /tmp/claude-login.log
chown paperclip:paperclip /tmp/claude-login.log

# ВАЖНО (grabli.md): Ink TUI крешит сессию сразу после выдачи токена.
# Без `script -qfec` лог теряется и токен (виден только 1 раз) пропадает.
# tmux -x 600 -y 50 + COLUMNS=600 чтобы URL не переносился.
tmux new-session -d -s claude-login -x 600 -y 50 \
  "script -qfec 'su - paperclip -c \"COLUMNS=600 HOME=/opt/paperclip claude setup-token\"' /tmp/claude-login.log"

sleep 10
CLEAN=$(cat /tmp/claude-login.log | tr -d '\r' | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

# Claude OAuth URL
URL=$(echo "$CLEAN" | grep -oE 'https://(claude\.ai|console\.anthropic\.com)/[^[:space:]]+' | head -1)
if [ -z "$URL" ]; then
  echo "❌ OAuth URL не найден. Лог:"
  echo "$CLEAN" | head -40
  exit 1
fi

echo ""
echo "CLAUDE_AUTH_URL=$URL"
echo ""
echo "Пользователь должен:"
echo "  1. Открыть URL в Chrome (залогинен в Claude)"
echo "  2. Авторизовать → получить authorization code"
echo "  3. Прислать код обратно"
echo ""
echo "Затем: bash claude_setup.sh $(hostname -I | awk '{print \$1}') <pass> submit <CODE>"
REMOTE

elif [ "$PHASE" = "submit" ]; then
  if [ -z "$CODE" ]; then
    echo "❌ нужен authorization code как 4-й аргумент"
    exit 1
  fi
  # Phase 2 — инжектим код в ожидающую tmux-сессию
  $SSH "root@$IP" bash <<REMOTE
set -uo pipefail
tmux send-keys -t claude-login "$CODE" Enter
sleep 8

CLEAN=\$(cat /tmp/claude-login.log | tr -d '\r' | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

# Вытаскиваем long-lived OAuth токен (sk-ant-oat01-...)
TOKEN=\$(echo "\$CLEAN" | grep -oE 'sk-ant-oat01-[A-Za-z0-9_-]+' | head -1)
if [ -z "\$TOKEN" ]; then
  echo "❌ Токен не распознан. Последние строки лога:"
  echo "\$CLEAN" | tail -30
  exit 1
fi

# Пишем в systemd drop-in для paperclip.service
mkdir -p /etc/systemd/system/paperclip.service.d
cat > /etc/systemd/system/paperclip.service.d/env.conf <<EOF
[Service]
Environment="CLAUDE_CODE_OAUTH_TOKEN=\$TOKEN"
EOF
chmod 600 /etc/systemd/system/paperclip.service.d/env.conf
systemctl daemon-reload
systemctl restart paperclip

echo ""
echo "✅ Claude токен сохранён в systemd env (масштаб видимости ограничен paperclip.service)"
echo "   paperclip.service перезапущен"
echo ""
echo "👉 В Paperclip UI: Agent → Claude Code (local) → Test now → ожидать Passed"
REMOTE
else
  echo "❌ Phase должна быть init или submit"
  exit 1
fi
