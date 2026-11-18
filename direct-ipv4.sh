#!/usr/bin/env bash
# =============================================================================
#  direct-ipv4.sh — заставить ноду ходить в интернет только по IPv4
#
#  Когда нужно: у сервера есть IPv6-адрес, но IPv6 наружу не работает (хостер
#  не маршрутизирует). Тогда Xray для сайтов с AAAA-записью (Google и др.)
#  выбирает IPv6 и висит до таймаута — «Google не открывается, ya.ru открывается».
#
#  Скрипт находит профиль ЭТОЙ ноды в панели (по IP сервера) и ставит outbound
#  "direct" -> domainStrategy UseIPv4. Остальное в профиле не трогает.
#  Запускать на сервере с нодой:
#     bash <(curl -fsSL https://raw.githubusercontent.com/qellyka/remnawave-installer/main/direct-ipv4.sh)
#     ... revert   — вернуть как было (убрать UseIPv4)
#  Переменные: PANEL_URL, API_TOKEN (берётся из /root/.rw_node_token), PROFILE_UUID
# =============================================================================
set -euo pipefail
TOKEN_FILE="/root/.rw_node_token"
CMD="${1:-apply}"
[[ "$CMD" == "apply" || "$CMD" == "revert" ]] || { echo "Команды: apply (по умолчанию) | revert"; exit 1; }

# --- диагностика: что с IPv4/IPv6 на этом сервере ---
chk() { curl "-$1" -s -o /dev/null --max-time 6 -w '%{http_code}' "https://$2" 2>/dev/null || true; }
V4=$(chk 4 www.google.com); V6=$(chk 6 www.google.com)
echo "  Google по IPv4: ${V4:-000}   по IPv6: ${V6:-000}"
if [[ "$CMD" == "apply" && "${V6:-000}" != "000" ]]; then
  echo "  IPv6 на сервере работает — правка не обязательна. Продолжаю всё равно."
fi
MY_IP=$(curl -4 -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p' || true)

PANEL_URL="${PANEL_URL:-}"
[[ -n "$PANEL_URL" ]] || read -rp "  URL панели (panel.example.com): " PANEL_URL
PANEL_URL="$(printf '%s' "$PANEL_URL" | tr -d '[:space:]')"; PANEL_URL="${PANEL_URL%/}"
[[ "$PANEL_URL" == http* ]] || PANEL_URL="https://$PANEL_URL"
API_TOKEN="${API_TOKEN:-}"
[[ -n "$API_TOKEN" || ! -s "$TOKEN_FILE" ]] || API_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[[ -n "$API_TOKEN" ]] || { read -rsp "  API-токен панели: " API_TOKEN; echo; API_TOKEN="$(printf '%s' "$API_TOKEN" | tr -d '[:space:]')"; }

RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" RW_CMD="$CMD" RW_MY_IP="$MY_IP" \
RW_PROFILE="${PROFILE_UUID:-}" python3 - <<'PYEOF'
import json, os, socket, sys, urllib.request
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PANEL + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOK); req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode() or "{}"); return d.get("response", d)
def resolve(a):
    try: return {i[4][0] for i in socket.getaddrinfo(a, None, socket.AF_INET)}
    except Exception: return set()

uuid = os.environ["RW_PROFILE"]
if not uuid:
    my_ip = os.environ["RW_MY_IP"]
    nodes = api("GET", "/api/nodes"); nodes = nodes.get("nodes", nodes) if isinstance(nodes, dict) else nodes
    mine = [n for n in nodes or [] if my_ip and my_ip in resolve(n.get("address", ""))
            and (n.get("configProfile") or {}).get("activeConfigProfileUuid")]
    if len(mine) == 1:
        uuid = mine[0]["configProfile"]["activeConfigProfileUuid"]
        print(f"  Нода: {mine[0].get('name')} ({mine[0].get('address')})")
    else:
        cand = [n for n in nodes or [] if (n.get("configProfile") or {}).get("activeConfigProfileUuid")]
        print(f"  Не смог однозначно найти ноду по IP {my_ip or '?'} — выбери:")
        for i, n in enumerate(cand, 1): print(f"    {i}) {n.get('name')}  {n.get('address')}")
        n = int(input("  Номер: ") or 0)
        if not 1 <= n <= len(cand): sys.exit("Отмена.")
        uuid = cand[n - 1]["configProfile"]["activeConfigProfileUuid"]

prof = api("GET", f"/api/config-profiles/{uuid}"); cfg = prof["config"]
outs = cfg.get("outbounds", [])
d = next((o for o in outs if o.get("tag") == "direct"), None)
if d is None: sys.exit("В профиле нет outbound «direct».")
st = d.setdefault("settings", {})
before = st.get("domainStrategy", "AsIs")
if os.environ["RW_CMD"] == "apply":
    st["domainStrategy"] = "UseIPv4"
else:
    st.pop("domainStrategy", None)
    if not st: d.pop("settings")
after = st.get("domainStrategy", "AsIs")
if before == after: print(f"  Профиль {prof.get('name')}: direct уже {after} — ничего не меняю."); sys.exit(0)
api("PATCH", "/api/config-profiles", {"uuid": uuid, "config": cfg})
print(f"  Готово: профиль {prof.get('name')}, direct: {before} -> {after}. Нода перезапустит Xray сама (секунды).")
PYEOF
