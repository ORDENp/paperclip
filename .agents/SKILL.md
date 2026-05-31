---
name: paperclip-deploy
description: Разворачивает Paperclip (paperclip.run, AI-orchestrator с веб-UI под свою LLM-подписку) на Aeza Cloud Amsterdam с нуля за 15-20 минут. Сервер 5 ₽/час почасовой биллинг, Anthropic/OpenAI напрямую без VPN. Пользователю задаём ТОЛЬКО 2 вопроса — (1) подписка (ChatGPT Plus / Claude Max) и (2) Aeza API-ключ; далее всё автоматически. Используй когда пользователь говорит «разверни Paperclip», «поставь Paperclip», «подними Paperclip», «Paperclip с нуля», «deploy Paperclip», «установи Paperclip на сервер». НЕ для общего VPS-деплоя (→ vdsina-deploy/timeweb-deploy), GPU-серверов под локальные LLM (→ gpu-servers), чистого API-ключа без веб-UI (→ claude-api).
verified: true
---

# Paperclip Deploy — 2 вопроса и готово

**Тестовый прогон end-to-end успешно пройден 2026-04-23 на Aeza NL-2 за ~15 минут.** Все грабли в `references/grabli.md`.

## Итог для пользователя

После запуска скилла пользователь получает:
- Работающий Paperclip UI по адресу `http://<IP>/` в Амстердаме
- CEO-аккаунт в своей «компании»
- Авторизованный локальный Codex CLI или Claude Code CLI на сервере (через device-auth flow)
- Test environment passed зелёным
- **5 ₽/час** почасовой биллинг (800 ₽ = ~6 дней непрерывной работы)

## Архитектурная оговорка: «пусть Paperclip использует мою подписку»

Если пользователь хочет, чтобы Paperclip работал **на его подписке** ChatGPT Plus / Claude Max, не отвечать автоматически «это невозможно».

**Правильная проверка:**
1. Сначала смотреть, есть ли у текущей версии Paperclip **local agent adapters**
2. Если есть `codex_local` / `claude_local` / другие `*_local` adapters — Paperclip может spawn'ить локальный CLI-агент, а тот уже ходит в провайдера через OAuth подписки
3. Только если local adapters отсутствуют — говорить про API-ключи, gateway или альтернативный путь

Это доменная логика именно для Paperclip-workflow, а не общий global rule.

## Два вопроса к пользователю — в ЭТОМ порядке

### Вопрос 1 из 2 — Какая подписка на ИИ

> **Привет. Разверну тебе Paperclip за 15 минут. Но сначала — какая у тебя подписка на ИИ? (ответь номером)**
>
> **1.** ChatGPT Plus ($20/мес) — будем использовать Codex CLI (рекомендовано, OpenAI не банит)
> **2.** Claude Pro / Max — будем использовать Claude Code CLI (⚠️ Anthropic банит подписки за использование в оркестраторах — риск)
> **3.** Нет ни того, ни другого — скажи, и я пришлю, где купить

По ответу запомнить `$LLM` = `codex` или `claude`. **Не продолжать дальше без ответа.**

### Вопрос 2 из 2 — Aeza API-ключ

Показать **всю инструкцию целиком одним сообщением**, без пошагового «жми Enter чтобы продолжить»:

> **Теперь нужен API-ключ Aeza — это позволит мне создать тебе сервер в Амстердаме автоматически.**
>
> **Если аккаунта Aeza нет** (5-7 минут):
> 1. Регистрация: зайди на **https://aeza.net** → правый верхний угол **«Регистрация»** → email, ФИО, телефон → подтверди email
> 2. Пополнение баланса: войди в ЛК https://my.aeza.net → левое меню **«Финансы»** → **«Пополнить»** → введи **800 ₽** → выбери способ **СБП** (моментально) → оплати телефоном
> 3. API-токен: https://my.aeza.net/settings/apikeys → **«Создать ключ»** → придумай имя («paperclip-deploy») → скопируй длинную строку формата `<число>_<hex32>` (пример: `6447_e9e335de9aee42bf80175d22dbff360c`)
>
> **Если аккаунт уже есть** — пропусти шаги 1-2, сразу на шаг 3.
>
> **Когда ключ готов — просто пришли мне его одним сообщением.** Ничего больше делать не надо.

После получения ключа записать как `AEZA_TOKEN`, валидировать через `GET /api/accounts/me`, показать баланс, и дальше **молча** прогнать весь deploy.

## Полный workflow (автоматика после 2 вопросов)

```
[User] → AEZA_TOKEN + LLM choice (codex|claude)
         ↓
[Phase 1] Probe: GET /accounts/me → баланс ≥ 100 ₽ (5 ₽/час × 20 часов буфер)
         ↓
[Phase 2] Aeza API: POST /services/orders с NL-2 (productId=398, term=hour, os=5, method=balance)
         ↓ wait status=active (~30-60 сек)
[Phase 3] reinstall с паролем: POST /services/:id/reinstall с {os:"ubuntu_2404", password:<random>}
         ↓ wait 45 сек пока reinstall не закончится
[Phase 4] SSH bootstrap: ufw 22/80/443 + fail2ban + unattended-upgrades
         ↓
[Phase 5] Install Paperclip: apt + Node 20 + npm i -g paperclipai + systemd + nginx
         ↓ paperclipai onboard -y --bind lan (ДО systemd start!)
         ↓ systemctl start paperclip (ExecStart=paperclipai run --bind lan)
         ↓
[Phase 6] Configure: jq-патч config.json (exposure→public, publicBaseUrl) + allowed-hostname <IP>
         ↓ systemctl restart paperclip
         ↓ paperclipai auth bootstrap-ceo --force --base-url http://<IP>
         ↓ → invite URL
         ↓
[Phase 7] Install LLM CLI + device-auth:
         codex:  npm i -g @openai/codex ; codex login --device-auth → URL+code
         claude: npm i -g @anthropic-ai/claude-code ; claude setup-token → URL+code
         ↓ отдать URL+code пользователю
[User] входит в браузере, подтверждает
         ↓ CLI автоматически poll'ит endpoint, пишет token в ~/.codex/auth.json или env
[Phase 8] Verify: codex login status = "Logged in using ChatGPT" / claude auth status OK
         ↓ hello probe → "hello"
         ↓
[DONE] Отдать пользователю invite URL + Test now инструкцию
```

## Запуск как один оркестратор

Агент пишет `AEZA_TOKEN` в env, не в `.env` (permission-safe), и запускает:

```bash
AEZA_TOKEN=<token> LLM=codex python3 .claude/skills/paperclip-deploy/scripts/aeza_deploy.py
```

Скрипт делает всё Phase 1-6 автоматически. После него:
- файл `/tmp/paperclip-deploy.state.json` содержит `{ip, service_id, root_pass, invite_url}`
- если что-то упало на фазе N — exit с кодом N и понятным сообщением

Потом запускается:
```bash
# для Codex
bash .claude/skills/paperclip-deploy/scripts/codex_setup.sh <IP> <root_pass>
# для Claude
bash .claude/skills/paperclip-deploy/scripts/claude_setup.sh <IP> <root_pass>
```

Оба скрипта печатают device-auth URL + one-time code в stdout. Агент парсит их, отдаёт пользователю, ждёт его «ок».

## КРИТИЧЕСКИЕ грабли (проверено в бою 2026-04-23)

Следующий агент **не должен** наступать на эти грабли — все уже поймали и зафиксировали:

| # | Грабля | Правильный способ |
|---|---|---|
| 1 | npm-пакет называется **`paperclipai`** (без scope) | `npm install -g paperclipai` — НЕ `@paperclipai/cli` |
| 2 | Нет команды `paperclipai start --port 3100` | `paperclipai run --bind lan` (порт 3100 задаётся в config) |
| 3 | `paperclipai run` падает с "No config found and terminal is non-interactive" | **Сначала** `paperclipai onboard -y --bind lan` (от юзера paperclip), потом `systemctl start paperclip` |
| 4 | После `onboard` exposure=`private` — внешний curl даёт 403 | jq-патч config.json: `exposure=public`, `auth.baseUrlMode=explicit`, `auth.publicBaseUrl=http://<IP>`, потом restart |
| 5 | Paperclip API возвращает JSON с сырыми `\n` в description полях — `json.loads()` бросает `JSONDecodeError: Invalid control character` | `json.loads(text, strict=False)` во ВСЕХ API-запросах к Aeza |
| 6 | `POST /services/orders` параметр `os` — числовой ID (5 для Ubuntu 24.04) | `{"parameters": {"os": 5}}` |
| 7 | `POST /services/:id/reinstall` параметр `os` — **string slug**, не число! | `{"os": "ubuntu_2404", "password": "..."}` (400 "os must be a string" если дать int) |
| 8 | Нет endpoint `/services/:id/password` или `/ctl/change_password` (все 500) | Установить пароль через **reinstall** — новый диск с нужным паролем |
| 9 | `codex login` без флагов открывает local callback `:1455` (headless не работает) | `codex login --device-auth` — обязательно этот флаг |
| 10 | `--use-device-code` — **несуществующий** флаг (устаревшая документация) | только `--device-auth` |
| 11 | `HEAD https://auth.openai.com/` → 403 выглядит как geo-block, но НЕ является им | не использовать HEAD `/` как probe — делать GET на реальные endpoints (например `GET /codex/device` после device-auth флоу) |
| 12 | VDSina Amsterdam часто полностью забит (все тарифы 400 "not enough resources") | Aeza как основной путь, VDSina — fallback |
| 13 | Timeweb Cloud больше не отдаёт Paperclip через `/presets/servers/marketplace` (404) | не использовать marketplace — ставить на чистый Ubuntu 24.04 через installer |
| 14 | В Aeza нет endpoint для SSH-ключей (500 на все `/ssh-keys`, `/user/ssh-keys` etc.) | использовать root + password через `sshpass`, ключ залить потом через SSH |
| 15 | Claude Max в оркестраторе = **риск бана** от Anthropic | предупредить пользователя, предложить Codex как безопасный дефолт |

## Типы ответов при проблемах во время deploy

| Симптом на фазе | Причина | Действие агента |
|---|---|---|
| 401 на `GET /accounts/me` | Кривой токен | Попросить пересоздать в `my.aeza.net/settings/apikeys` |
| `POST /services/orders` 403 `"Not enough balance"` | Мало баланса | Сказать точную сумму к пополнению + напомнить про СБП |
| `reinstall` висит > 3 мин без `status=active` | Проблема на стороне Aeza | Подождать ещё 2 мин, если не поднимается — tкет в саппорт `my.aeza.net/support` |
| `curl http://<IP>/` → 403 после Phase 6 | Не прошёл jq-патч / или allowed-hostname | Перезапустить только Phase 6 (`configure_paperclip.sh`) |
| `codex login status` → `not logged in` | Пользователь не ввёл код вовремя (15 мин TTL) | Перезапустить Phase 7, выдать новый URL+code |
| Test now в UI → красный с 401 | Пользователь ввёл код в другом браузере / не в той сессии ChatGPT | Перезапустить Phase 7, попросить открыть URL именно в том Chrome где залогинен в ChatGPT Plus |

## Что лежит в `scripts/`

| Файл | Что делает | Когда запускать |
|---|---|---|
| `aeza_deploy.py` | **Главный оркестратор.** Phase 1-6 целиком: probe → order → wait active → reinstall → bootstrap → install Paperclip → configure → invite URL. На выходе `/tmp/paperclip-deploy.state.json` | Первым, после получения `AEZA_TOKEN` |
| `install_paperclip_on_ubuntu.sh` | Node 20 + `paperclipai` + systemd (с `onboard -y` ДО start) + nginx :80→:3100. Вызывается из `aeza_deploy.py` | Внутри оркестратора |
| `configure_paperclip.sh` | jq-патч config.json → public + allowed-hostname + bootstrap CEO invite | Внутри оркестратора |
| `codex_setup.sh` | `codex login --device-auth` в фоне от юзера paperclip, вытаскивает URL+code из `/tmp/codex-login.log` | После оркестратора если `LLM=codex` |
| `claude_setup.sh` | `claude setup-token` через `script -qfec` (Ink TUI crash protection), вытаскивает URL+code | После оркестратора если `LLM=claude` |
| `aeza_inventory.py` | Probe баланса, дата-центров, существующих серверов. Для ручной диагностики | По команде пользователя «посмотри что у меня в Aeza» |

## Aeza quick reference

| Параметр | Значение |
|---|---|
| Base URL | `https://my.aeza.net/api` |
| Auth | header `X-API-Key: <token>` (НЕ `Bearer`) |
| Токен | `my.aeza.net/settings/apikeys` |
| Баланс | `GET /accounts/me` → `data.balance` |
| NL-2 productId | `398` (2c/4GB/60GB Amsterdam Ryzen 9 7950X3D, dedicated) |
| Ubuntu 24.04 | create: `os: 5` (integer) · reinstall: `os: "ubuntu_2404"` (string slug) |
| Цена | 5 ₽/час, 1415 ₽/мес |
| JSON парсинг | `json.loads(text, strict=False)` — из-за `\n` в description |

Подробности — `references/aeza-api-reference.md`.

## Connectivity с Aeza NL (проверено 2026-04-23)

| Endpoint | Результат |
|---|---|
| `https://api.anthropic.com/` | 404 (доступен) |
| `https://chatgpt.com/` | 103 Early Hints (доступен) |
| `https://auth.openai.com/codex/device` | работает, device-auth flow проходит |
| `codex login --device-auth` | URL + 8-символьный код, TTL 15 мин |
| `claude setup-token` | OAuth URL + manual code entry, long-lived token TTL 1 год |

**Выводы:** ни Anthropic ни OpenAI не блокируют Aeza NL IP. Shadowsocks НЕ нужен.

## Связанные

- [references/grabli.md](references/grabli.md) — расширенные описания всех 15 граблей с примерами ошибок
- [references/aeza-api-reference.md](references/aeza-api-reference.md) — полный справочник Aeza API
- [references/aeza-registration.md](references/aeza-registration.md) — копипаст-готовая инструкция для пользователя
- [.claude/skills/vdsina-deploy/SKILL.md](../vdsina-deploy/SKILL.md) — fallback при недоступности Aeza (Amsterdam капасити может быть забита)
- [.claude/rules/08-working-patterns.md](../../rules/08-working-patterns.md) — раздел «AI-оркестраторы через local agent adapters»

## Legacy: старые пути (не использовать по умолчанию)

- Timeweb KZ + Shadowsocks — работал до 2026-04-22, но Timeweb убрал Paperclip marketplace. Остался только чистый Ubuntu + install script — но прокси заморочка, а Aeza дешевле (5 ₽/ч vs 901 ₽/мес = 1.25 ₽/ч) и без прокси.
- VDSina Amsterdam — capacity часто забита, нужно ждать retry. Если Aeza упадёт — смотри `vdsina-deploy`.
