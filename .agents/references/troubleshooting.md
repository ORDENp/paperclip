# Paperclip Deploy — частые проблемы

## «Command not found in PATH: claude»

В Paperclip UI при Test environment. Причина:

1. Claude CLI не установлен: `ssh root@<IP> "which claude"` — пусто
2. Установлен, но не в PATH пользователя paperclip: `su - paperclip -c 'which claude'` — пусто
3. В PATH paperclip user'а есть, но не в PATH systemd-unit (systemd чистит PATH по умолчанию до `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`)

Фикс: `npm install -g @anthropic-ai/claude-code` устанавливает в `/usr/bin/claude` (symlink из `/usr/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`) — это стандартный PATH, должно подхватиться везде. Если не подхватилось:

```ini
# /etc/systemd/system/paperclip.service.d/env.conf
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

## OAuth error 403 на setup-token

См. [claude-setup-token.md](claude-setup-token.md) — раздел «OAuth error: Request failed with status code 403».

TL;DR: проверить `curl -x http://127.0.0.1:1081 https://api.anthropic.com` с сервера. Если 403 — прокси не рабочий. Если 404/200 — прокси ок, проблема где-то ещё.

## Invite not available / Invite expired

1. URL обрезан в передаче. Проверить что пользователь открыл **полный** `pcp_bootstrap_<40+hex>`, а не только префикс `pcp_bootstrap`. В логах сервера:
   ```bash
   ssh root@<IP> "grep '/invite' /opt/paperclip/.paperclip/instances/default/logs/server.log | tail -5"
   ```
   Видно какой URL реально запрашивался.

2. Invite истёк (TTL был маленький) — создать новый:
   ```bash
   ssh root@<IP> "su - paperclip -c 'paperclipai auth bootstrap-ceo --force --base-url http://<IP> --expires-hours 168'"
   ```

3. Invite уже использован — создаются one-time. `--force` генерирует **новый** инвайт даже если CEO уже есть (для случаев «потерял пароль»).

## Paperclip не стартует после patch config.json

`systemctl status paperclip` показывает failed. Обычно в логе:
```
Invalid config: <какое-то поле> must be <тип>
```

Откатить backup:
```bash
ssh root@<IP> "ls /opt/paperclip/.paperclip/instances/default/config.json.bak.* | tail -1 | xargs -I{} cp {} /opt/paperclip/.paperclip/instances/default/config.json"
systemctl restart paperclip
```

Потом разбираться с патчем. Частые ошибки:
- Забыл поставить `auth.publicBaseUrl` когда `deploymentMode=authenticated && exposure=public` — Paperclip требует explicit URL
- Сломал JSON синтаксис (jq обычно защищает, но если руками — проверить `python3 -m json.tool config.json`)

## External curl `http://<IP>` возвращает 403

После marketplace-install и до Phase 6 — это нормально, Paperclip в `deploymentMode: local_trusted`. Если уже прогнали configure_paperclip.sh и всё равно 403:

1. Проверить `allowedHostnames` в config.json — должен содержать `<IP>`:
   ```bash
   ssh root@<IP> "jq '.server.allowedHostnames, .server.exposure, .server.deploymentMode' /opt/paperclip/.paperclip/instances/default/config.json"
   ```
2. Проверить что paperclip действительно перезапустился после patch: `systemctl show paperclip --property=ActiveEnterTimestamp`
3. Если всё выглядит правильно, но 403 — проверить nginx:
   ```bash
   ssh root@<IP> "curl -s -H 'Host: <IP>' http://127.0.0.1:3100/ | head -5"
   ```
   Если напрямую 200, а через nginx 403 — проблема в nginx конфиге.

## sslocal не стартует

`systemctl status sslocal` failed. Обычно:

1. **Неправильный метод шифрования** — если SS-сервер на `chacha20-ietf-poly1305`, а клиент настроен на `aes-256-gcm`. Проверить:
   ```bash
   ssh root@<IP> "jq '.method' /etc/sslocal.json"
   ```
2. **Неправильный пароль** — ss-server молча reject connections, не даёт диагностики
3. **Блокировка порта** — Timeweb блокирует некоторые порты (25, 465, 587, 53413 и т.д., full list в API). Если SS-сервер на одном из них — не подключится. Смена порта на 443 обычно решает.

Диагностика:
```bash
ssh root@<IP> "
    journalctl -u sslocal --no-pager -n 30
    # Попробовать вручную подключиться
    /usr/local/bin/sslocal -c /etc/sslocal.json -v 2>&1 | head -20
"
```

## Claude отвечает «Your credit balance is too low»

Значит `CLAUDE_CODE_OAUTH_TOKEN` либо не установлен, либо Claude CLI его не подхватил и пытается использовать ANTHROPIC_API_KEY (который не задан → fallback на Claude.com subscription, которая проверяет баланс **аккаунта провайдера токена**).

Проверить:
```bash
ssh root@<IP> "systemctl show paperclip --property=Environment | grep OAUTH"
```

Если пусто — env.conf не подхватился:
```bash
ssh root@<IP> "
    cat /etc/systemd/system/paperclip.service.d/env.conf
    systemctl daemon-reload
    systemctl restart paperclip
"
```

## Paperclip UI не обновляется после настройки adapter

Кнопка Test environment возвращает старый результат. Причина — React app кэширует. Фикс:
- Cmd+Shift+R (hard reload)
- Или открыть в incognito — точно без кэша

## Как полностью сбросить Paperclip

Если что-то сломалось и хочется начать заново **без пересоздания сервера**:

```bash
ssh root@<IP> "
    systemctl stop paperclip
    # бэкап на всякий
    cp -r /opt/paperclip/.paperclip /opt/paperclip/.paperclip.backup
    # сносим инстанс
    rm -rf /opt/paperclip/.paperclip/instances/default
    # onboard заново
    su - paperclip -c 'paperclipai onboard'
    # затем нужно пройти весь configure_paperclip.sh заново
"
```

## Paperclip потребляет много RAM

Embedded Postgres + Node.js + npm exec + Ink watchers — базовый memory footprint ~300 MB. Под нагрузкой (несколько активных issues) может подняться до 1-1.5 GB. Для минимальной 2 CPU / 4 GB конфы — окей с запасом. Если закончится — сервер swap'ит и всё медленно.

Мониторинг:
```bash
ssh root@<IP> "systemctl show paperclip --property=MemoryCurrent,MemoryPeak"
ssh root@<IP> "free -m"
```
