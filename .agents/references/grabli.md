# Грабли paperclip-deploy (собраны в боевом прогоне 2026-04-23)

Все 15 ловушек с реальными ошибками, корневыми причинами и фиксами. Следующий агент должен ПРОЧИТАТЬ этот файл ДО первого запуска — сэкономит ~2 часа.

---

## 1. npm-пакет называется `paperclipai` (без scope)

**Ошибка:** `npm install -g @paperclipai/cli` работает, но бинарник `paperclipai` оказывается не установленным, или установлен в странный путь.

**Фикс:** `npm install -g paperclipai` — primary, даёт глобальный бинарник `/usr/bin/paperclipai`. Проверено на `paperclipai@2026.416.0`.

---

## 2. Нет команды `paperclipai start`

**Ошибка:**
```
error: unknown command 'start'
paperclip.service: Main process exited, code=exited, status=1/FAILURE
```

systemd rematches 10+ раз и сдаётся.

**Фикс:** команда — `paperclipai run`. Порт задаётся в config.json (по дефолту 3100), флагом `--port` **не задаётся**.

```ini
ExecStart=/usr/bin/paperclipai run --bind lan
```

---

## 3. `paperclipai run` падает без предварительного `onboard`

**Ошибка:**
```
paperclipai run
■ No config found and terminal is non-interactive.
│ Run paperclipai onboard once, then retry paperclipai run.
```

**Фикс:** ДО `systemctl start paperclip` выполнить один раз от юзера paperclip:
```bash
su - paperclip -c 'HOME=/opt/paperclip paperclipai onboard -y --bind lan'
```

`-y` = non-interactive, accept defaults. `--bind lan` = слушать `0.0.0.0:3100` (нужно для nginx reverse proxy).

---

## 4. После `onboard` exposure = private → внешний curl 403

**Ошибка:** локально `curl http://127.0.0.1/` возвращает 200, но с внешнего мака на `http://<IP>/` — 403.

**Причина:** onboard создаёт config.json с `server.exposure: "private"` и `auth.baseUrlMode: "auto"`.

**Фикс:** jq-патч:
```bash
jq '.server.exposure = "public"
    | .auth.baseUrlMode = "explicit"
    | .auth.publicBaseUrl = "http://<IP>"' \
   /opt/paperclip/.paperclip/instances/default/config.json
```

И отдельно:
```bash
su - paperclip -c 'HOME=/opt/paperclip paperclipai allowed-hostname <IP>'
systemctl restart paperclip
```

Без `allowed-hostname` даже с `exposure: public` будет 403.

---

## 5. Aeza API возвращает JSON с сырыми `\n` → `json.loads()` крашится

**Ошибка Python:**
```
json.decoder.JSONDecodeError: Invalid control character at: line 1 column 3521 (char 3520)
```

**Причина:** Aeza в `description` полях продуктов оставляет сырые `\n` без escape. Стандартный JSON парсер по умолчанию `strict=True` не принимает control characters.

**Фикс:** во **всех** вызовах к `my.aeza.net/api`:
```python
json.loads(response_text, strict=False)
```

В скриптах paperclip-deploy — `aeza_deploy.py::api()` уже это делает.

---

## 6. `POST /services/orders` — поле `os` это **число** (integer)

Пример вызова для создания сервера:
```json
{
  "productId": 398,
  "term": "hour",
  "parameters": {"os": 5},   // ← int для create
  "method": "balance"
}
```

**`os=5`** соответствует Ubuntu 24.04 (получено через `GET /api/os`).

---

## 7. `POST /services/:id/reinstall` — поле `os` это **строка-slug** (НЕ число!)

**Ошибка если дать int:**
```json
400 Bad Request
{"error":"Validation Error","payload":["os must be a string"]}
```

**Фикс:** при reinstall — slug:
```json
{"os": "ubuntu_2404", "password": "..."}
```

Идёт вразрез с create (где int). Aeza inconsistency. Получить slugs можно через `GET /api/os` → поле `slug`.

---

## 8. Aeza не отдаёт root-пароль через API после create

**Симптом:** После `POST /services/orders` сервер активен, IP известен, но `payload.password` пуст, а endpoints `/services/:id/password`, `/services/:id/reset-password`, `/ctl/change_password` все возвращают 500 (routes не реализованы).

**Фикс:** использовать `POST /services/:id/reinstall` с нашим сгенерированным паролем. Reinstall передиплоит Ubuntu с новым паролем, который мы знаем. Время ~60 сек.

```python
import secrets, string
password = "PcT" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16))
api("POST", f"/services/{sid}/reinstall", token, {"os": "ubuntu_2404", "password": password})
time.sleep(45)  # ждём пока sshd поднимется
```

---

## 9. `codex login` (без флагов) на headless не работает

**Ошибка:** codex по умолчанию пытается поднять local HTTP callback на `:1455` и ждёт redirect от OpenAI. На удалённом сервере без публичного `:1455` это не доходит.

**Фикс:** `codex login --device-auth` — device code flow (URL + short code, polling).

---

## 10. `--use-device-code` — несуществующий флаг

**Ошибка:** `codex login --use-device-code` → `error: unknown argument`.

**Причина:** устаревшая документация / confusion с другими CLI.

**Фикс:** **только** `--device-auth`. Проверено на `codex 0.122.0`.

---

## 11. `HEAD https://auth.openai.com/` → 403 выглядит как geo-block, но НЕ является им

**Ложная паника:** агент делает probe `curl -sI https://auth.openai.com/` и получает 403, делает вывод "Cloudflare блокирует IP", хотя это просто HEAD-запрос на root-path.

**Фикс:** не использовать root-path HEAD как probe. Настоящая проверка — запустить `codex login --device-auth` и посмотреть, приходит ли URL+code в stdout. Если приходит — endpoint доступен.

---

## 12. VDSina Amsterdam часто забит

**Ошибка (при попытке VDSina fallback):**
```
400 Bad Request
"This datacenter does not have enough resources to host this tariff plan.
 Select the junior tariff or try to place an order after a while."
```

Одновременно могут быть забиты **ВСЕ** тарифы в AMS (154, 136, 137, 138, 146 Hi-CPU, 153 Constructor).

**Фикс:** Aeza в Амстердаме стабильнее по капасити. Если всё же нужен VDSina — перепроверить через 30-60 мин или переключиться в Moscow+Shadowsocks (но это уже legacy-путь).

---

## 13. Timeweb больше не отдаёт Paperclip в API marketplace

**Ошибка:** `GET /api/v1/presets/servers/marketplace` → 404. Endpoints `/api/v1/images`, `/api/v1/apps` возвращают пустые списки.

**Причина:** Timeweb убрал публичный список marketplace-приложений из API (на 2026-04). В UI ещё можно выбрать образ при создании через браузер, но через API — нет.

**Фикс:** ставить на чистый Ubuntu 24.04 через `install_paperclip_on_ubuntu.sh` — работает везде одинаково.

---

## 14. В Aeza нет endpoint для SSH-ключей

**Ошибка:** `GET /ssh-keys`, `/user/ssh-keys`, `/account/ssh-keys` — все 500 "Proxy internal server error".

**Фикс:** использовать root + password (`sshpass`) для первого входа. Если нужен SSH-key auth — залить свой pub-ключ в `~/.ssh/authorized_keys` через первую SSH-сессию.

В скрипте `install_paperclip_on_ubuntu.sh` это не сделано — можно добавить если нужно. Но для MVP деплоя Paperclip SSH-key необязателен — всё управление идёт через веб-UI после Phase 6.

---

## 15. Claude Max в оркестраторе = риск бана от Anthropic

**Не ошибка, а гайдлайн.** Anthropic отслеживает использование подписки Claude Max / Pro в автоматизированных системах (включая Paperclip, OpenClaw) и может забанить аккаунт за нарушение ToS — подписка формально для интерактивной работы, не для 24/7 оркестрации.

**Фикс:**
- По умолчанию предлагать **Codex / ChatGPT Plus** (OpenAI policy мягче)
- Если пользователь всё же хочет Claude Max — предупредить про риск, пометить как "демо/личный"
- Для продакшена — рекомендовать API-ключ Anthropic (платишь per-token, без подписки)

---

## Timing всех фаз (эталон с прогона 2026-04-23)

| Phase | Что | Время |
|---|---|---|
| 1 | probe баланс | 2 сек |
| 2 | order + wait active | 30-90 сек |
| 3 | reinstall с паролем + wait SSH | 60-90 сек |
| 4 | SSH bootstrap (ufw + fail2ban) | 30-60 сек |
| 5 | install Paperclip (Node + npm + systemd + nginx) | 90-120 сек |
| 6 | configure (jq-патч + allowed-hostname + bootstrap CEO) | 30 сек |
| 7 | codex login --device-auth (до выдачи URL+code) | 15 сек |
| User | пользователь вводит код в браузере | ~30 сек |
| 8 | codex poll'ит + auth.json + verify | 10 сек |
| **Всего** | — | **~10-15 мин** |

Если укладываешься в 15 мин — всё хорошо. Если > 20 мин — проверь логи, скорее всего какой-то phase crashed и молча висит.
