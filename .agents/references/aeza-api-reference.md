# Aeza API — справочник для Paperclip deploy

Источник: GitHub [AezaGroup/dev-docs](https://github.com/AezaGroup/dev-docs) + эмпирически проверено 2026-04-23 в боевом прогоне.

## Базовое

| Параметр | Значение |
|---|---|
| Base URL | `https://my.aeza.net/api` |
| Auth header | `X-API-Key: <token>` — **НЕ `Bearer`**, НЕ `Authorization` |
| Токен | `my.aeza.net/settings/apikeys` → «Создать ключ» |
| Формат токена | `<число>_<hex32>`, например `6447_e9e335de9aee42bf80175d22dbff360c` |
| Формат ответов | JSON, `{data: ..., error: ...}` |
| **Критично** | Парсить **только** через `json.loads(text, strict=False)` — в descriptions сырые `\n` |

## Ключевые endpoints (используются в `aeza_deploy.py`)

### `GET /accounts/me` — аккаунт + баланс

```json
{
  "id": 805717,
  "email": "user@example.com",
  "balance": 600,
  "withdrawBalance": 0,
  "totalReplenished": 1094,
  "bonusBalance": 0,
  ...
}
```

### `GET /services/products` — каталог всех тарифов

Большой массив (~400+ items). Для Paperclip фильтр:
```python
[p for p in items
 if p.get("type") == "vps"
 and p.get("group",{}).get("payload",{}).get("label","").startswith(("NL-","DE-","AT-","FR-","FI-","SE-"))
 and not p.get("group",{}).get("payload",{}).get("isDisabled")]
```

Ключевое для нас — **productId=398 (NL-2 Amsterdam dedicated 2c/4GB/60GB)**:
```json
{
  "id": 398,
  "type": "vps",
  "name": "NL-2",
  "prices": {
    "hour": 5,
    "month": 1415,
    "year": 14943
  },
  "group": {
    "payload": {"label": "NL-DEDICATED", "isDisabled": false}
  },
  "summaryConfiguration": {
    "cpu": {"base": 2},
    "ram": {"base": 4},
    "rom": {"base": 60}
  }
}
```

### `GET /os` — список OS (id + slug)

Ubuntu 24.04 = **id=5, slug="ubuntu_2404"**. Важно — create принимает **int id**, reinstall — **string slug**.

### `POST /services/orders` — заказать сервер

```json
{
  "count": 1,
  "term": "hour",                        // "hour" | "day" | "month" | "year"
  "name": "paperclip-test",
  "productId": 398,
  "parameters": {"os": 5},               // INT!
  "autoProlong": false,
  "method": "balance"
}
```

Ответ:
```json
{
  "data": {
    "transaction": {
      "id": 27244878,
      "amount": -5,                       // списано ₽ за первый час
      "status": "performed",
      "serviceId": 1772494                // ← это ID сервера для будущих operations
    }
  }
}
```

### `GET /services/:id` — детали сервера

Сразу после order: `status: "activation_wait"`, `ip: null`. Через 30-90 сек: `status: "active"`, `ip: "213.165.40.27"`.

```json
{
  "data": {
    "items": [{
      "id": 1772494,
      "status": "active",
      "ip": "213.165.40.27",
      "ips": [{"value": "213.165.40.27", "type": "ipv4", ...}],
      "timestamps": {"createdAt": 1776892658, "expiresAt": 1776896258}
    }]
  }
}
```

### `POST /services/:id/reinstall` — переустановить ОС с нашим паролем

```json
{
  "os": "ubuntu_2404",           // STRING slug! НЕ int
  "password": "PcT7c0d382b426fc42f"
}
```

Отвечает `HTTP 201` без тела. Ждать **45-60 сек** пока новая Ubuntu поднимется и sshd начнёт слушать.

### `DELETE /services/:id` — удалить сервер

`HTTP 204`. Теряются деньги за уже потраченные часы (`remove the service without refund`).

### `GET /services` — список всех сервисов пользователя

Возвращает `{data: {items: [...], total: N}}`.

## Endpoints которые **НЕ работают** (500, не тратьте время)

- `/ssh-keys`, `/user/ssh-keys`, `/account/ssh-keys`
- `/services/:id/password`, `/services/:id/change-password`, `/services/:id/reset-password`
- `/ctl/*`, `/services/:id/ctl/<action>`
- `/me`, `/profile/me`, `/user`, `/account`, `/users/me`

Перечислены в `grabli.md`. Смена пароля **только через `reinstall`**.

## Локации (группы → labels)

| Label | Локация | Цена 2c/4GB (NL-2 эквивалент) |
|---|---|---|
| **NL-DEDICATED** | **Амстердам** 🇳🇱 | **1415 ₽/мес** (дефолт для Paperclip) |
| DE-DEDICATED | Франкфурт 🇩🇪 | обычно isDisabled=true на момент проверки |
| FI-SHARED | Хельсинки 🇫🇮 | дешевле, но shared |
| SE-DEDICATED | Швеция 🇸🇪 | ~2362 ₽/мес |
| AT-SHARED | Вена 🇦🇹 | средняя цена |
| FR-SHARED | Париж 🇫🇷 | — |
| RU-SHARED | Москва/СПб 🇷🇺 | **НЕ использовать** — geo-блок Anthropic/OpenAI |

Дефолт — **NL-DEDICATED** (productId=398), ибо capacity всегда есть + Anthropic/OpenAI без прокси.

## Connectivity проверена 2026-04-23 с Aeza NL IP 213.165.40.27

| Endpoint | Ответ |
|---|---|
| `https://api.anthropic.com/` | HTTP 404 (доступен, root-path без auth) |
| `https://chatgpt.com/` | HTTP 103 Early Hints (доступен) |
| `https://auth.openai.com/codex/device` | работает для device-auth flow |
| `codex login --device-auth` | URL + code за 3-5 сек, token за 3-10 сек после ввода |
| `claude setup-token` | OAuth URL + manual code entry, токен sk-ant-oat01-... TTL 1 год |

**Никакого VPN / Shadowsocks не нужно.**

## curl-примеры

```bash
TOKEN=6447_<hex32>

# Баланс
curl -s -H "X-API-Key: $TOKEN" https://my.aeza.net/api/accounts/me | jq .balance

# Заказать сервер
curl -s -X POST -H "X-API-Key: $TOKEN" -H "Content-Type: application/json" \
  https://my.aeza.net/api/services/orders \
  -d '{"count":1,"term":"hour","name":"paperclip-test","productId":398,"parameters":{"os":5},"autoProlong":false,"method":"balance"}' \
  | jq .data.transaction.serviceId

# Детали
curl -s -H "X-API-Key: $TOKEN" https://my.aeza.net/api/services/1772494 | jq '.data.items[0] | {status, ip}'

# Reinstall с паролем
curl -s -X POST -H "X-API-Key: $TOKEN" -H "Content-Type: application/json" \
  https://my.aeza.net/api/services/1772494/reinstall \
  -d '{"os":"ubuntu_2404","password":"PcT7c0d382b426fc42f"}'

# Удалить
curl -s -X DELETE -H "X-API-Key: $TOKEN" https://my.aeza.net/api/services/1772494
```
