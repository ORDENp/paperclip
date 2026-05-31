# Управление Paperclip с мака

Три способа дотянуться до Paperclip-инстанса с локальной машины пользователя.

## A · Paperclip MCP server

Если Paperclip поддерживает MCP (смотреть в UI → Settings → Integrations, или в документации `paperclip.run/docs/mcp`):

1. В Paperclip Settings → API tokens → создать токен с scope `read+write`
2. В `~/.claude.json` (или в `.mcp.json` проекта) добавить:

```json
{
  "mcpServers": {
    "paperclip": {
      "command": "npx",
      "args": ["-y", "@paperclipai/mcp-server"],
      "env": {
        "PAPERCLIP_URL": "http://<IP>",
        "PAPERCLIP_TOKEN": "<api-token>"
      }
    }
  }
}
```

3. Перезапустить Claude Code — увидишь tools `mcp__paperclip__create_issue`, `mcp__paperclip__list_agents` и т.п.

**Когда использовать:** нативная интеграция, Claude Code может напрямую создавать issues, назначать агентам, читать комменты — без curl/шелла.

**Status:** MCP server для Paperclip в 2026-04 ещё не документирован в open source. Проверять `npm view @paperclipai/mcp-server` или `github.com/paperclipai/mcp-server`. Если пакета нет — используй вариант B или C.

## B · SSH-туннель + локальный доступ

Проброс портов — самый простой и работает всегда:

```bash
ssh -L 3100:127.0.0.1:3100 -N -f root@<IP>
```

Флаги:
- `-L 3100:127.0.0.1:3100` — локальный :3100 → на сервере :3100 (Paperclip)
- `-N` — не выполнять команд, только туннель
- `-f` — в фоне

После этого:
- В браузере на маке: `http://localhost:3100` — та же UI но без geo-block проверки Paperclip (допустимо потому что трафик через localhost)
- curl/Python скрипты: `http://localhost:3100/api/*`

Закрыть туннель:
```bash
pkill -f 'ssh -L 3100:127.0.0.1:3100'
```

**Когда использовать:** временный доступ когда нужно быстро что-то проверить или дебажить. Нет зависимости от наличия MCP.

## C · REST API напрямую

Paperclip API доступен по `http://<IP>/api/*` (с token-ом):

1. UI → Company Settings → **API tokens** → Create
2. Токен сохранить в `.env` (например, `PAPERCLIP_API_TOKEN_<server>=...`)

Примеры:

```bash
# Список компаний
curl -H "Authorization: Bearer $PAPERCLIP_API_TOKEN" http://<IP>/api/companies

# Создать issue
curl -X POST http://<IP>/api/companies/<company-id>/issues \
  -H "Authorization: Bearer $PAPERCLIP_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title": "Explore Hugo vs Jekyll", "description": "Compare for blog migration", "assignee_agent_id": "<ceo-agent-id>"}'

# Прочитать ответ агента
curl -H "Authorization: Bearer $PAPERCLIP_API_TOKEN" \
  http://<IP>/api/issues/<issue-id>/messages
```

Python-обёртка для scripts:

```python
import os, requests
BASE = f"http://{os.environ['PAPERCLIP_SERVER_IP']}"
H = {"Authorization": f"Bearer {os.environ['PAPERCLIP_API_TOKEN']}"}

def create_issue(company_id, title, description, agent_id=None):
    body = {"title": title, "description": description}
    if agent_id:
        body["assignee_agent_id"] = agent_id
    return requests.post(f"{BASE}/api/companies/{company_id}/issues", headers=H, json=body).json()
```

**Когда использовать:** автоматизация, scripts, интеграция с другими системами (например, Telegram-бот создаёт issue при сообщении в канал).

## Claude Code / Codex → Paperclip как SRE-агент

Интересный паттерн — запускать Claude Code локально, а он через один из способов выше посылает задачи агентам Paperclip:

1. Настроить MCP (вариант A) или прописать curl-скрипты в `.claude/skills/paperclip-control/`
2. Claude Code делает «issue» через MCP/curl
3. Paperclip агент (на сервере) делает реальную работу через свой Claude Max
4. Результат возвращается в issue → Claude Code читает → показывает пользователю

Это позволяет одной подпиской Claude Max поддерживать **несколько Claude Code сессий** (на сервере через Paperclip + на маке локально) — удобно для продолжительных background-задач (ресёрч, генерация отчётов).

Ограничения:
- Rate-limit Claude Max один на аккаунт — не получится запускать параллельно много тяжёлых задач
- Нужно следить за долгими сессиями через Paperclip (они не timeout'ят автоматически как CLI)

## Сравнительная таблица

| Вариант | Для чего | Сложность | Зависимости |
|---|---|---|---|
| A · MCP | Ежедневная работа, нативно в Claude Code | Низкая (если MCP сервер готов) | Paperclip MCP package |
| B · SSH-туннель | Отладка, временный доступ | Минимальная | `ssh` |
| C · REST API | Автоматизация, скрипты, интеграции | Средняя | `curl` или `requests` |
