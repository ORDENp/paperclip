#!/usr/bin/env bash
# Проверяет что Codex успешно получил OAuth-токен после device-auth.
# Usage: bash verify_codex.sh <IP> <root_password>

set -euo pipefail

IP="${1:?}"
PASS="${2:?}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"

echo "🔍 Проверка Codex auth на root@$IP..."
$SSH "root@$IP" bash <<'REMOTE'
set -uo pipefail

# 1. auth.json существует
if [ ! -f /opt/paperclip/.codex/auth.json ]; then
  echo "❌ /opt/paperclip/.codex/auth.json нет — пользователь ещё не ввёл код, или код истёк"
  exit 1
fi
ls -la /opt/paperclip/.codex/auth.json

# 2. Статус
STATUS=$(su - paperclip -c 'HOME=/opt/paperclip codex login status' 2>&1)
echo "$STATUS"

if echo "$STATUS" | grep -q "Logged in using ChatGPT"; then
  echo "✅ Codex авторизован через ChatGPT Plus"
else
  echo "⚠️  Нестандартный статус:"
  echo "$STATUS"
fi

# 3. Hello probe — реальный вызов OpenAI API
echo ""
echo "=== hello probe через codex exec ==="
su - paperclip -c 'HOME=/opt/paperclip COLUMNS=200 codex exec --json --dangerously-bypass-approvals-and-sandbox --model gpt-5.3-codex "Say only the word hello"' 2>&1 | tail -3

# 4. Restart paperclip чтобы он переподтянул auth.json
systemctl restart paperclip
echo "✅ paperclip.service перезапущен"
REMOTE

echo
echo "👉 Дальше в Paperclip UI:"
echo "   1. Agent → Codex (local)"
echo "   2. Test now → должен быть зелёный Passed"
echo "   3. Next → Task → Launch"
