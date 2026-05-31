#!/usr/bin/env python3
"""Главный оркестратор деплоя Paperclip на Aeza Cloud Amsterdam.

Phase 1-6:  probe → order → reinstall с паролем → SSH bootstrap → install Paperclip → configure
На выходе: IP, root-пароль, invite URL, записанные в /tmp/paperclip-deploy.state.json

Usage:
    AEZA_TOKEN=<token> python3 aeza_deploy.py
    # Или с кастомным server name:
    AEZA_TOKEN=<token> python3 aeza_deploy.py --name paperclip-prod

Exit codes:
    0 — успех
    1 — нет AEZA_TOKEN
    2 — недостаточно баланса
    3 — ошибка API Aeza (401/403/500)
    4 — сервер не поднялся за 5 минут
    5 — SSH недоступен после активации
    6 — ошибка установки Paperclip на сервере
    7 — ошибка configure phase
"""
import argparse
import json
import os
import pathlib
import secrets
import string
import subprocess
import sys
import time
import urllib.error
import urllib.request


API = "https://my.aeza.net/api"
STATE_FILE = pathlib.Path("/tmp/paperclip-deploy.state.json")
SCRIPTS_DIR = pathlib.Path(__file__).parent
NL_2_PRODUCT_ID = 398  # Amsterdam 2c/4GB/60GB Ryzen 9 7950X3D, dedicated, 5 ₽/час
UBUNTU_OS_ID_INT = 5  # для POST /services/orders
UBUNTU_OS_SLUG = "ubuntu_2404"  # для POST /services/:id/reinstall
TERM = "hour"  # почасовой биллинг, не блокирует месячный резерв


def log(msg):
    print(msg, flush=True)


def api(method, path, token, body=None):
    """Aeza API wrapper. json.loads(..., strict=False) обязателен — в ответах сырые \n."""
    req = urllib.request.Request(
        API + path,
        method=method,
        headers={"X-API-Key": token, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            text = r.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise SystemExit(f"❌ HTTP {e.code} {method} {path}: {detail[:500]}")
    if not text.strip():
        return {}
    return json.loads(text, strict=False)  # strict=False из-за \n в description


def phase1_probe(token):
    """Проверить что токен валиден и баланс позволяет держать сервер."""
    log("📋 Phase 1 — probe Aeza (токен + баланс)")
    try:
        me = api("GET", "/accounts/me", token)
    except SystemExit as e:
        if "401" in str(e):
            log("❌ Токен невалиден (401). Пересоздай: my.aeza.net/settings/apikeys")
            sys.exit(3)
        raise
    bal = float(me.get("balance") or 0)
    log(f"   ✓ Аккаунт {me.get('email','?')} id={me.get('id','?')}")
    log(f"   ✓ Баланс: {bal} ₽")
    # Минимум на 20 часов работы = 100 ₽
    if bal < 100:
        log(f"❌ Баланс {bal} ₽ меньше 100 ₽. Пополни my.aeza.net → Финансы → СБП.")
        sys.exit(2)
    if bal < 500:
        log(f"   ⚠️  Баланс < 500 ₽ — на сутки хватит, рекомендую пополнить до 800 ₽")


def phase2_order(token, name):
    """Заказать NL-2 Amsterdam с Ubuntu 24.04, дождаться активации."""
    log(f"🚀 Phase 2 — заказ сервера NL-2 Amsterdam (productId={NL_2_PRODUCT_ID})")
    resp = api("POST", "/services/orders", token, {
        "count": 1,
        "term": TERM,
        "name": name,
        "productId": NL_2_PRODUCT_ID,
        "parameters": {"os": UBUNTU_OS_ID_INT},
        "autoProlong": False,
        "method": "balance",
    })
    tx = resp.get("data", {}).get("transaction", {})
    service_id = tx.get("serviceId")
    if not service_id:
        log(f"❌ Не вижу serviceId в ответе: {json.dumps(resp, ensure_ascii=False)[:500]}")
        sys.exit(3)
    amount = tx.get("amount", 0)
    log(f"   ✓ serviceId={service_id}, списано {-amount} ₽")

    log(f"⏳ Жду status=active (обычно 30-90 сек)...")
    for i in range(20):
        time.sleep(15)
        d = api("GET", f"/services/{service_id}", token)["data"]["items"][0]
        st = d.get("status")
        ip = d.get("ip")
        log(f"   [{i+1}/20] status={st} ip={ip}")
        if st == "active" and ip:
            log(f"   ✓ Сервер активен, IP={ip}")
            return service_id, ip
    log("❌ Сервер не стал active за 5 минут")
    sys.exit(4)


def phase3_reinstall_with_password(token, service_id, ip):
    """Reinstall Ubuntu 24.04 с заданным паролем (API не выдаёт пароль иначе)."""
    log("🔐 Phase 3 — reinstall с нашим паролем (API пароль не отдаёт)")
    # Генерируем читаемый пароль
    alphabet = string.ascii_letters + string.digits
    password = "PcT" + "".join(secrets.choice(alphabet) for _ in range(16))

    api("POST", f"/services/{service_id}/reinstall", token, {
        "os": UBUNTU_OS_SLUG,  # ВАЖНО: slug string, не int! (400 "os must be a string")
        "password": password,
    })
    log(f"   ✓ reinstall запущен")
    log(f"⏳ Жду пока Ubuntu переустановится (~60 сек)...")

    time.sleep(45)  # reinstall обычно 30-60 сек
    # Пинг SSH
    for i in range(12):
        r = subprocess.run(
            ["nc", "-z", "-w", "5", ip, "22"],
            capture_output=True,
        )
        if r.returncode == 0:
            log(f"   ✓ SSH 22 открыт (попытка {i+1})")
            time.sleep(5)  # sshd полностью поднимается
            return password
        log(f"   [{i+1}/12] SSH пока закрыт, жду 15 сек...")
        time.sleep(15)
    log("❌ SSH не открылся после reinstall")
    sys.exit(5)


def phase4_5_install(ip, password):
    """SSH bootstrap + установка Paperclip."""
    log("📦 Phase 4-5 — SSH bootstrap + установка Paperclip")
    installer = SCRIPTS_DIR / "install_paperclip_on_ubuntu.sh"
    if not installer.exists():
        log(f"❌ Скрипт не найден: {installer}")
        sys.exit(6)
    r = subprocess.run(
        ["bash", str(installer), ip, password],
        capture_output=False,  # показывать прогресс
    )
    if r.returncode != 0:
        log(f"❌ Установка Paperclip упала (exit {r.returncode})")
        sys.exit(6)
    log("   ✓ Paperclip установлен и запущен")


def phase6_configure(ip, password):
    """Patch config.json + allowed-hostname + bootstrap CEO invite."""
    log("⚙️  Phase 6 — configure + bootstrap CEO")
    configurator = SCRIPTS_DIR / "configure_paperclip.sh"
    r = subprocess.run(
        ["bash", str(configurator), ip, password],
        capture_output=True,
        text=True,
    )
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    if r.returncode != 0:
        log(f"❌ configure_paperclip.sh упал (exit {r.returncode})")
        sys.exit(7)

    # Извлекаем invite URL из stdout
    invite_url = None
    for line in r.stdout.splitlines():
        if "Invite URL:" in line:
            invite_url = line.split("Invite URL:", 1)[1].strip()
            break
        if "/invite/pcp_bootstrap_" in line:
            import re
            m = re.search(r"http://[^\s]+/invite/pcp_bootstrap_[a-f0-9]+", line)
            if m:
                invite_url = m.group(0)
                break
    if not invite_url:
        log("⚠️  Не нашёл invite URL в stdout, проверь вручную")
    return invite_url


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="paperclip-prod")
    args = ap.parse_args()

    token = os.environ.get("AEZA_TOKEN")
    if not token:
        log("❌ AEZA_TOKEN не задан. Экспортируй: AEZA_TOKEN=<твой_токен> python3 ...")
        sys.exit(1)

    start = time.time()
    phase1_probe(token)
    service_id, ip = phase2_order(token, args.name)
    password = phase3_reinstall_with_password(token, service_id, ip)
    phase4_5_install(ip, password)
    invite_url = phase6_configure(ip, password)

    elapsed = int(time.time() - start)

    # Сохраняем state
    state = {
        "ip": ip,
        "service_id": service_id,
        "root_pass": password,
        "invite_url": invite_url,
        "deployed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elapsed_seconds": elapsed,
    }
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2))

    log("")
    log("=" * 60)
    log(f"✅ Paperclip развёрнут за {elapsed // 60} мин {elapsed % 60} сек")
    log(f"   IP:         {ip}")
    log(f"   service_id: {service_id}")
    log(f"   root pass:  {password}")
    log(f"   invite URL: {invite_url or '(не распознан, смотри логи)'}")
    log(f"   state:      {STATE_FILE}")
    log("=" * 60)
    log("")
    log("👉 Следующий шаг — настройка LLM:")
    log(f"   Codex:  bash {SCRIPTS_DIR / 'codex_setup.sh'} {ip} {password}")
    log(f"   Claude: bash {SCRIPTS_DIR / 'claude_setup.sh'} {ip} {password}")


if __name__ == "__main__":
    main()
