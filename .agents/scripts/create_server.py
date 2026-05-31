#!/usr/bin/env python3
"""Создаёт сервер Timeweb Cloud из marketplace-образа Paperclip.

Usage:
    python3 create_server.py --location nl-1 --name paperclip-prod
    python3 create_server.py --location ru-1 --preset 2cpu-4gb-50ssd --name my-pc

Требования:
    TIMEWEB_CLOUD_TOKEN в ./.env или экспортирован в окружении.

Выход:
    IP, root-пароль и server_id в stdout. Пишет PAPERCLIP_SERVER_IP и
    PAPERCLIP_SERVER_ID в .env (пароль НЕ пишется — только выводится).
"""
import argparse
import json
import os
import pathlib
import sys
import time
import urllib.request


API = "https://api.timeweb.cloud/api/v1"


def load_env(path):
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip("'\""))


def api(method, path, token, body=None):
    req = urllib.request.Request(
        API + path,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None,
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--location", default="kz-1", choices=["ru-1", "ru-2", "ru-3", "nl-1", "de-1", "kz-1"],
                    help="kz-1 = Казахстан (дефолт, дешёвые legacy-тарифы, без VPN). "
                         "ru-* = Москва/СПб/НСК (нужен VPN-ключ). "
                         "nl-1 = Амстердам / de-1 = Франкфурт (дорого, без VPN).")
    ap.add_argument("--name", required=True, help="Имя сервера")
    ap.add_argument("--preset-cpu", type=int, default=2)
    ap.add_argument("--preset-ram", type=int, default=4096, help="MB")
    ap.add_argument("--preset-disk", type=int, default=51200, help="MB")
    args = ap.parse_args()

    # Подтянуть .env
    load_env(pathlib.Path(".env"))
    token = os.environ.get("TIMEWEB_CLOUD_TOKEN")
    if not token:
        print("❌ TIMEWEB_CLOUD_TOKEN не найден в ./.env или окружении", file=sys.stderr)
        sys.exit(1)

    # 1. Находим Paperclip marketplace image
    print("🔍 Ищу Paperclip в marketplace...")
    mp = api("GET", "/presets/servers/marketplace", token)
    items = mp.get("marketplace", []) or mp.get("items", [])
    paperclip = next((x for x in items if "paperclip" in x.get("name", "").lower()), None)
    if not paperclip:
        print("❌ Paperclip не найден в marketplace. Проверь вручную в UI.", file=sys.stderr)
        sys.exit(1)
    image_id = paperclip["id"]
    print(f"   image_id = {image_id}")

    # 2. Находим подходящий preset — берём САМЫЙ ДЕШЁВЫЙ из подходящих.
    # Важно: в одной локации могут быть legacy-тарифы (дешевле в 7x) и новые (дороже).
    # Например в kz-1 для 2c/4GB/50GB есть id=2939 за 721 ₽ и id=3797 за 5420 ₽.
    # Всегда берём минимальную цену — legacy хватает под Paperclip.
    print(f"🔍 Ищу preset {args.preset_cpu} CPU / {args.preset_ram} MB / {args.preset_disk} MB / {args.location}...")
    presets = api("GET", "/presets/servers", token)["server_presets"]
    candidates = [p for p in presets
                   if p["cpu"] == args.preset_cpu
                   and p["ram"] == args.preset_ram
                   and p["disk"] == args.preset_disk
                   and p["location"] == args.location]
    candidates.sort(key=lambda x: x.get("price", 999999))
    preset = candidates[0] if candidates else None
    if len(candidates) > 1:
        print(f"   найдено {len(candidates)} подходящих, беру самый дешёвый:")
        for c in candidates:
            marker = "✓" if c is preset else " "
            print(f"     {marker} id={c['id']:5d} | {c.get('price','?'):>5} ₽/мес")
    if not preset:
        print(f"❌ Preset {args.preset_cpu}x{args.preset_ram}x{args.preset_disk} для {args.location} не найден", file=sys.stderr)
        sys.exit(1)
    preset_id = preset["id"]
    price = preset.get("price", "?")
    print(f"   preset_id = {preset_id}, цена ~{price} ₽/мес")

    # 2.5. Pre-flight: проверяем что баланса хватит на месячный резерв + IPv4 + запас
    try:
        bal_data = api("GET", "/account/finances", token)["finances"]
        balance = bal_data.get("balance", 0)
        # Timeweb блокирует месячный резерв вперёд. Для IPv4 — дополнительно ~180 ₽/мес.
        # Закладываем preset_price * 1 мес + 180 (IPv4) + 500 (запас на эксперименты и почасовое списание).
        required = price + 180 + 500 if isinstance(price, (int, float)) else 2000
        if balance < required:
            print(f"❌ Недостаточно баланса. Есть: {balance} ₽. Нужно минимум: {required} ₽")
            print(f"   (месячный резерв preset {price} ₽ + IPv4 180 ₽ + запас 500 ₽)")
            print(f"   Пополни https://timeweb.cloud/my/finances и запусти скрипт заново.")
            sys.exit(2)
        print(f"   баланс OK: {balance} ₽ ≥ {required} ₽")
    except Exception as e:
        print(f"⚠️  не смог проверить баланс (продолжаю): {e}")

    # 3. Создаём сервер
    body = {
        "name": args.name,
        "preset_id": preset_id,
        "image_id": image_id,
        "is_ddos_guard": False,
    }
    print(f"🚀 Создаю сервер '{args.name}'...")
    r = api("POST", "/servers", token, body)
    sid = r["server"]["id"]
    print(f"   server_id = {sid}")

    # 4. Ждём provisioning
    print("⏳ Жду статус 'on' (обычно ~90 сек)...")
    start = time.time()
    while time.time() - start < 600:
        s = api("GET", f"/servers/{sid}", token)["server"]
        if s["status"] == "on":
            break
        time.sleep(10)
    else:
        print("❌ Timeout: сервер не поднялся за 10 минут", file=sys.stderr)
        sys.exit(1)

    # 4.5. Проверяем есть ли IPv4 — если нет (часто для AMS/FRA), заказываем отдельно
    ip = next((x["ip"] for x in s["networks"][0]["ips"] if x["type"] == "ipv4"), None)
    if not ip:
        print("📡 IPv4 не выдан автоматически (частое поведение для AMS/FRA). Заказываю отдельно...")
        try:
            ipv4_req = api("POST", f"/servers/{sid}/ips", token, {"type": "ipv4"})
            # Ждём пока IPv4 появится в сетевых интерфейсах
            for _ in range(30):
                s = api("GET", f"/servers/{sid}", token)["server"]
                ip = next((x["ip"] for x in s["networks"][0]["ips"] if x["type"] == "ipv4"), None)
                if ip:
                    break
                time.sleep(5)
        except Exception as e:
            print(f"❌ Не смог заказать IPv4: {e}")
            print(f"   Попробуй руками в UI: https://timeweb.cloud/my/servers/{sid}/network")
            sys.exit(3)
        if not ip:
            print("❌ IPv4 не появился за 2.5 мин. Проверь в UI.")
            sys.exit(3)
        print(f"   IPv4 добавлен: {ip}")

    root_pass = s["root_pass"]

    # 5. Пишем в .env (только id и ip; пароль — в stdout один раз)
    env = pathlib.Path(".env")
    env.touch(exist_ok=True)
    lines = env.read_text().splitlines()
    lines = [l for l in lines if not l.startswith(("PAPERCLIP_SERVER_IP=", "PAPERCLIP_SERVER_ID="))]
    lines.append(f"PAPERCLIP_SERVER_IP={ip}")
    lines.append(f"PAPERCLIP_SERVER_ID={sid}")
    env.write_text("\n".join(lines) + "\n")

    print()
    print("✅ Сервер готов!")
    print(f"   IP:        {ip}")
    print(f"   ID:        {sid}")
    print(f"   root pass: {root_pass}")
    print(f"   SSH:       ssh root@{ip}")
    print()
    print("⚠️  Пароль root сохрани в менеджере — в .env его не пишу.")
    print("   Следующий шаг: bash scripts/ssh_bootstrap.sh", ip, f"'{root_pass}'")


if __name__ == "__main__":
    main()
