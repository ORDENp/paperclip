#!/usr/bin/env bash
# Первичная настройка SSH доступа к Paperclip-серверу.
# Копирует публичный ключ пользователя в authorized_keys сервера,
# дальше все команды скилла идут без пароля.
#
# Usage: bash ssh_bootstrap.sh <IP> '<root-password>'

set -euo pipefail

IP="${1:?Usage: $0 <IP> <root-pass>}"
ROOT_PASS="${2:?Usage: $0 <IP> <root-pass>}"

if ! command -v sshpass >/dev/null; then
    echo "❌ sshpass не установлен. На macOS: brew install hudochenkov/sshpass/sshpass"
    exit 1
fi

PUB_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"
if [[ ! -f "$PUB_KEY_PATH" ]]; then
    PUB_KEY_PATH="${HOME}/.ssh/id_rsa.pub"
fi
if [[ ! -f "$PUB_KEY_PATH" ]]; then
    echo "❌ Нет ни id_ed25519.pub, ни id_rsa.pub в ~/.ssh/. Сгенерируй: ssh-keygen -t ed25519"
    exit 1
fi

PUB_KEY=$(cat "$PUB_KEY_PATH")

echo "🔑 Копирую $PUB_KEY_PATH на $IP..."
export SSHPASS="$ROOT_PASS"
sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 \
    root@"$IP" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qF '$PUB_KEY' ~/.ssh/authorized_keys || echo '$PUB_KEY' >> ~/.ssh/authorized_keys && echo OK_KEY"

unset SSHPASS

echo "🩺 Sanity-check сервиса Paperclip..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@"$IP" "
    echo '--- OS ---'
    . /etc/os-release && echo \"\$PRETTY_NAME\"
    echo '--- paperclip.service ---'
    systemctl is-active paperclip || { echo '⚠️ paperclip не active — marketplace-образ ещё не закончил cloud-init?'; exit 1; }
    echo '--- nginx :80 ---'
    ss -tln | grep -q ':80 ' && echo 'nginx listening' || echo '⚠️ nginx не слушает :80'
    echo '--- ports :3100 (paperclip internal) ---'
    ss -tln | grep -q '127.0.0.1:3100 ' && echo 'paperclip listening on :3100' || echo '⚠️ :3100 не активен'
"

echo
echo "✅ SSH bootstrap готов."
echo "   Дальше:"
echo "     • если сервер в РФ → bash scripts/setup_ss.sh $IP '<ssconf-url>'"
echo "     • иначе             → bash scripts/configure_paperclip.sh $IP"
