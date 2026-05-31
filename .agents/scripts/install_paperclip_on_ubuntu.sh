#!/usr/bin/env bash
# Ставит Paperclip на чистый Ubuntu 24.04 (после reinstall с паролем).
# Node 20 + paperclipai (npm) + systemd (onboard ДО run) + nginx :80 → :3100.
#
# Usage:
#   bash install_paperclip_on_ubuntu.sh <IP> <root_password>
#
# ВСЕ грабли сегодняшнего прогона учтены — см. references/grabli.md

set -euo pipefail

IP="${1:?IP первым аргументом}"
PASS="${2:?root пароль вторым аргументом}"

# macOS — проверка sshpass
if [[ "$OSTYPE" == "darwin"* ]] && ! command -v sshpass >/dev/null; then
  echo "❌ sshpass не установлен. Поставь: brew install hudochenkov/sshpass/sshpass"
  exit 1
fi

SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"

echo "📦 Bootstrap + Paperclip на root@$IP..."
$SSH "root@$IP" bash <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "📦 apt update (тихо)..."
apt-get update -qq
apt-get upgrade -y -qq

# 1. Базовая гигиена — ufw 22/80/443, fail2ban, unattended-upgrades, jq (понадобится в configure)
echo "🛡  ufw + fail2ban + unattended-upgrades + jq..."
apt-get install -y -qq ufw fail2ban unattended-upgrades jq curl
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
systemctl enable --now fail2ban >/dev/null
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null

# 2. Node.js 20.x (NodeSource) — не 22+, Paperclip может плеваться на новых API
if ! node --version 2>/dev/null | grep -q '^v20'; then
  echo "📦 Ставлю Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs
fi
echo "   Node: $(node --version)"

# 3. Системный пользователь paperclip (home = /opt/paperclip)
if ! id paperclip &>/dev/null; then
  echo "👤 user paperclip..."
  useradd -m -d /opt/paperclip -s /bin/bash paperclip
fi

# 4. ГРАБЛЯ №1: пакет называется paperclipai (БЕЗ @scope), НЕ @paperclipai/cli
echo "📦 npm install -g paperclipai..."
npm install -g paperclipai 2>&1 | tail -3
echo "   paperclipai CLI: $(paperclipai --version 2>/dev/null || echo 'installed')"

chown -R paperclip:paperclip /opt/paperclip

# 5. ГРАБЛЯ №3: Paperclip требует `onboard` ДО первого `run` — создаёт config.json.
# Делаем non-interactive через `-y --bind lan` от юзера paperclip.
echo "🚀 paperclipai onboard -y --bind lan (создаёт config.json)..."
su - paperclip -c 'HOME=/opt/paperclip COLUMNS=200 paperclipai onboard -y --bind lan' 2>&1 | tail -15

# 6. ГРАБЛЯ №2: ExecStart = `paperclipai run --bind lan` (НЕ `start --port 3100` — такой команды нет)
echo "⚙️  systemd unit..."
cat > /etc/systemd/system/paperclip.service <<'EOF'
[Unit]
Description=Paperclip AI Orchestrator
After=network.target

[Service]
Type=simple
User=paperclip
WorkingDirectory=/opt/paperclip
Environment="HOME=/opt/paperclip"
ExecStart=/usr/bin/paperclipai run --bind lan
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now paperclip

# Ждём пока Paperclip инициализирует embedded Postgres и начнёт слушать :3100
echo "⏳ жду пока Paperclip слушает :3100..."
for i in $(seq 1 24); do
  if curl -sf -o /dev/null http://127.0.0.1:3100/; then
    echo "   ✓ Paperclip listens (попытка $i)"
    break
  fi
  sleep 5
done

# 7. nginx reverse proxy :80 → :3100 с WebSocket upgrade (Paperclip использует socket.io)
echo "🌐 nginx..."
apt-get install -y -qq nginx
cat > /etc/nginx/sites-available/paperclip <<'EOF'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  client_max_body_size 50m;

  location / {
    proxy_pass http://127.0.0.1:3100;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 86400;
  }
}
EOF
ln -sf /etc/nginx/sites-available/paperclip /etc/nginx/sites-enabled/paperclip
rm -f /etc/nginx/sites-enabled/default
nginx -t >/dev/null
systemctl reload nginx

echo
systemctl --no-pager --quiet is-active paperclip && echo "✅ paperclip.service: active"
systemctl --no-pager --quiet is-active nginx && echo "✅ nginx: active"
REMOTE

echo
echo "✅ Install phase готов. Дальше → configure_paperclip.sh"
