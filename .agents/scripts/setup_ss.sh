#!/usr/bin/env bash
# Разворачивает shadowsocks-rust клиент на сервере как systemd-сервис.
# Поддерживает как ssconf:// URL (SIP008 JSON), так и одиночный ss:// URL.
#
# Listeners:
#   127.0.0.1:1080 — SOCKS5
#   127.0.0.1:1081 — HTTP (для HTTPS_PROXY в Claude/Node.js)
#
# Usage:
#   bash setup_ss.sh <IP> '<ssconf://host/path или ss://...>'

set -euo pipefail

IP="${1:?Usage: $0 <IP> <ssconf-or-ss-url>}"
URL="${2:?Usage: $0 <IP> <ssconf-or-ss-url>}"

SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$IP"

# 1. Парсим конфиг
if [[ "$URL" == ssconf://* ]]; then
    # SIP008: скачиваем JSON
    HTTP_URL="https://${URL#ssconf://}"
    echo "📥 Скачиваю SIP008 config с $HTTP_URL..."
    JSON=$(curl -s --max-time 15 "$HTTP_URL")
elif [[ "$URL" == ss://* ]]; then
    # ss:// — парсим через python (base64 decode + URL split)
    JSON=$(python3 -c "
import base64, json, urllib.parse, sys
u = urllib.parse.urlparse('$URL')
creds = u.username or ''
# ss://base64userinfo@host:port или ss://userinfo@host:port
if '@' not in creds and u.hostname is None:
    # whole thing base64'd after ss://
    pad = '=' * (-len(creds) % 4)
    decoded = base64.urlsafe_b64decode(creds + pad).decode()
    method, password = decoded.split(':', 1)
    host, port = u.fragment, None  # fallback — shouldn't happen for standard ss://
    print('ERROR: unusual ss:// format, parse manually', file=sys.stderr); sys.exit(1)
else:
    pad = '=' * (-len(creds) % 4)
    try:
        decoded = base64.urlsafe_b64decode(creds + pad).decode()
        method, password = decoded.split(':', 1)
    except Exception:
        method, password = creds.split(':', 1)
    host = u.hostname
    port = u.port
print(json.dumps({'server': host, 'server_port': port, 'method': method, 'password': password}))
")
else
    echo "❌ URL должен начинаться с ssconf:// или ss://" >&2
    exit 1
fi

SERVER=$(echo "$JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['server'])")
PORT=$(echo "$JSON"   | python3 -c "import json,sys; print(json.load(sys.stdin)['server_port'])")
METHOD=$(echo "$JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['method'])")
PASSWORD=$(echo "$JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['password'])")

echo "   SS server: $SERVER:$PORT ($METHOD)"

# 2. Ставим shadowsocks-rust
echo "📦 Ставлю shadowsocks-rust (sslocal) на $IP..."
$SSH "
    if [ -f /usr/local/bin/sslocal ] && /usr/local/bin/sslocal --version >/dev/null 2>&1; then
        echo '   уже установлен: '\$(/usr/local/bin/sslocal --version)
    else
        ARCH=x86_64-unknown-linux-gnu
        URL=\$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
            | grep browser_download_url | grep \$ARCH.tar.xz | grep -v 'v2ray\\|sha256' | head -1 | cut -d'\"' -f4)
        curl -sSL \$URL -o /tmp/ss.tar.xz
        tar -xf /tmp/ss.tar.xz -C /tmp
        install -m 755 /tmp/sslocal /usr/local/bin/sslocal
        /usr/local/bin/sslocal --version
    fi
"

# 3. Пишем конфиг с двумя listeners (SOCKS5 + HTTP)
echo "⚙️  Пишу /etc/sslocal.json..."
$SSH "cat > /etc/sslocal.json" <<EOF
{
  "server": "$SERVER",
  "server_port": $PORT,
  "password": "$PASSWORD",
  "method": "$METHOD",
  "mode": "tcp_and_udp",
  "locals": [
    {"local_address": "127.0.0.1", "local_port": 1080, "protocol": "socks"},
    {"local_address": "127.0.0.1", "local_port": 1081, "protocol": "http"}
  ]
}
EOF
$SSH "chmod 600 /etc/sslocal.json"

# 4. systemd unit
echo "⚙️  Пишу /etc/systemd/system/sslocal.service..."
$SSH "cat > /etc/systemd/system/sslocal.service" <<'EOF'
[Unit]
Description=Shadowsocks-rust local client for Paperclip
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sslocal -c /etc/sslocal.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

$SSH "systemctl daemon-reload && systemctl enable --now sslocal && sleep 2 && systemctl is-active sslocal"

# 5. Smoke-test
echo
echo "🧪 Smoke-test через прокси:"
$SSH "
    ip=\$(curl -s --max-time 10 -x http://127.0.0.1:1081 https://ipinfo.io/json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"ip\"], d.get(\"country\",\"?\"), d.get(\"city\",\"?\"))')
    echo '   Исходящий IP через прокси: '\$ip
    code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x http://127.0.0.1:1081 https://api.anthropic.com/)
    echo '   api.anthropic.com → '\$code' (ожидаем не 403)'
    if [ \"\$code\" = '403' ]; then
        echo '   ⚠️ Anthropic всё ещё режет — прокси не работает или выходной IP тоже в блок-листе'
        exit 1
    fi
"

echo
echo "✅ VPN-прокси готов."
echo "   Дальше: bash scripts/configure_paperclip.sh $IP"
