#!/usr/bin/env bash
# Phase 6: patch config.json → exposure=public + allowed-hostname + bootstrap CEO invite.
# Вызывается после install_paperclip_on_ubuntu.sh.
#
# Usage:
#   bash configure_paperclip.sh <IP> <root_password>
#
# Stdout: среди прочего — строка вида "Invite URL: http://<IP>/invite/pcp_bootstrap_<hex48>"

set -euo pipefail

IP="${1:?IP первым аргументом}"
PASS="${2:?root пароль вторым аргументом}"

SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"

echo "⚙️  Configure root@$IP..."
$SSH "root@$IP" bash <<REMOTE
set -euo pipefail

CONFIG=/opt/paperclip/.paperclip/instances/default/config.json

# ГРАБЛЯ №4: после onboard exposure=private → внешний curl 403.
# Правим: exposure=public, auth.baseUrlMode=explicit, auth.publicBaseUrl=http://<IP>
jq '.server.exposure = "public" | .auth.baseUrlMode = "explicit" | .auth.publicBaseUrl = "http://$IP"' \$CONFIG > \$CONFIG.new
chown paperclip:paperclip \$CONFIG.new
mv \$CONFIG.new \$CONFIG

# Добавляем IP в allowed-hostnames (без этого даже public даёт 403 на внешний хост)
su - paperclip -c "HOME=/opt/paperclip paperclipai allowed-hostname $IP" 2>&1 | tail -5

# Рестарт после изменения config
systemctl restart paperclip
sleep 15

echo
echo "=== local curl test ==="
curl -s -o /dev/null -w "http://127.0.0.1/ → %{http_code}\n" http://127.0.0.1/ || true

# Bootstrap CEO invite (одноразовый токен, первая регистрация = CEO)
echo
echo "=== bootstrap-ceo ==="
su - paperclip -c "HOME=/opt/paperclip paperclipai auth bootstrap-ceo --force --base-url http://$IP --expires-hours 168" 2>&1
REMOTE

echo
echo "✅ Configure готов. Если нужен — запусти codex_setup.sh / claude_setup.sh"
