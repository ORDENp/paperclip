#!/usr/bin/env bash
# Headless OAuth для Codex CLI под подпиской ChatGPT Plus на Aeza сервере.
#
# Проверено end-to-end 2026-04-23: всё работает с Aeza Amsterdam без прокси.
#
# Usage:
#   bash codex_setup.sh <IP> <root_password>
#
# Печатает в stdout:
#   DEVICE_AUTH_URL=https://auth.openai.com/codex/device
#   DEVICE_CODE=XXXX-XXXX
# Агент парсит эти две строки и отдаёт пользователю.

set -euo pipefail

IP="${1:?IP первым аргументом}"
PASS="${2:?root пароль вторым аргументом}"

SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"

echo "📦 Устанавливаю @openai/codex и запускаю device-auth на root@$IP..."

# Заливаем helper-скрипт на сервер (чтобы избежать zsh quoting hell)
cat > /tmp/codex-launch.sh <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail

# 1. Убиваем прошлые попытки codex login
pkill -u paperclip -f 'codex login' 2>/dev/null || true
sleep 1

# 2. Если Codex ещё не установлен — ставим
if ! command -v codex >/dev/null 2>&1; then
  npm install -g @openai/codex 2>&1 | tail -3
fi
echo "codex версия: $(codex --version 2>/dev/null || echo 'installed')"

# 3. ГРАБЛЯ №9 и №10: флаг ТОЛЬКО --device-auth
#    НЕ `--use-device-code` (устаревшая документация, такого флага нет)
#    НЕ `codex login` без флагов (открывает local callback :1455, на headless не работает)
rm -f /tmp/codex-login.log
su - paperclip -c 'COLUMNS=600 HOME=/opt/paperclip nohup codex login --device-auth > /tmp/codex-login.log 2>&1 &'
sleep 12

# 4. Извлекаем URL и one-time code
# Очищаем ANSI escape-коды (Ink TUI добавляет кучу \x1b[...])
CLEAN=$(cat /tmp/codex-login.log | tr -d '\r' | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

URL=$(echo "$CLEAN" | grep -oE 'https://auth\.openai\.com/[^[:space:]]*' | head -1)
CODE=$(echo "$CLEAN" | grep -oE '[A-Z0-9]{4}-[A-Z0-9]{4,5}' | head -1)

if [ -z "$URL" ] || [ -z "$CODE" ]; then
  echo "❌ Не удалось извлечь URL/code. Полный лог:"
  echo "$CLEAN"
  exit 1
fi

echo ""
echo "DEVICE_AUTH_URL=$URL"
echo "DEVICE_CODE=$CODE"
SCRIPT

sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/codex-launch.sh "root@$IP:/root/codex-launch.sh"
$SSH "root@$IP" "bash /root/codex-launch.sh"

echo
echo "👉 Отдай DEVICE_AUTH_URL и DEVICE_CODE пользователю."
echo "   Он открывает URL в Chrome (залогинен в ChatGPT Plus), вводит код."
echo "   Codex автоматически poll'ит endpoint и пишет токен в /opt/paperclip/.codex/auth.json."
echo ""
echo "🔍 Проверка через ~30 секунд после ввода кода пользователем:"
echo "   bash $(dirname "$0")/verify_codex.sh $IP $PASS"
