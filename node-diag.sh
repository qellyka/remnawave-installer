#!/usr/bin/env bash
# =============================================================================
#  node-diag.sh — проверить маршрутизацию ноды БЕЗ клиента
#
#  Берёт из панели профиль этой ноды, поднимает временный Xray из образа ноды с
#  теми же outbounds и правилами (вход — локальный socks) и прогоняет через него
#  несколько сайтов. Видно, какой путь (direct / warp / to-exit) и какой сайт
#  ломается. Если здесь всё 200/30x, а у клиента не открывается — дело в клиенте.
#  Запускать на сервере с нодой:
#     bash <(curl -fsSL https://raw.githubusercontent.com/qellyka/remnawave-installer/main/node-diag.sh)
#  Переменные: PANEL_URL, API_TOKEN (из /root/.rw_node_token), PROFILE_UUID, URLS
# =============================================================================
set -euo pipefail
NODE_DIR="${NODE_DIR:-/opt/remnanode}"
TOKEN_FILE="/root/.rw_node_token"
URLS="${URLS:-https://www.google.com https://ya.ru https://gemini.google.com/app https://www.gstatic.com/generate_204 https://chatgpt.com https://www.youtube.com}"
for c in curl python3 docker; do command -v "$c" >/dev/null || { echo "Нужен $c"; exit 1; }; done
WORK="$(mktemp -d /tmp/rw-diag.XXXXXX)"; chmod 700 "$WORK"
trap 'docker rm -f rw-diag >/dev/null 2>&1; rm -rf "$WORK"' EXIT

echo "== Сервер напрямую (без Xray)"
for v in 4 6; do
  printf '  IPv%s google: %s\n' "$v" "$(curl -"$v" -s -o /dev/null --max-time 6 -w '%{http_code}' https://www.google.com || true)"
done

NODE_IMAGE=$(grep -oE 'image:[[:space:]]*[^[:space:]]+' "$NODE_DIR/docker-compose.yml" 2>/dev/null | head -1 | awk '{print $2}' || true)
NODE_IMAGE="${NODE_IMAGE:-ghcr.io/remnawave/node:latest}"
MY_IP=$(curl -4 -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p' || true)

PANEL_URL="${PANEL_URL:-}"
[[ -n "$PANEL_URL" ]] || read -rp "URL панели (panel.example.com): " PANEL_URL
PANEL_URL="$(printf '%s' "$PANEL_URL" | tr -d '[:space:]')"; PANEL_URL="${PANEL_URL%/}"
[[ "$PANEL_URL" == http* ]] || PANEL_URL="https://$PANEL_URL"
API_TOKEN="${API_TOKEN:-}"
[[ -n "$API_TOKEN" || ! -s "$TOKEN_FILE" ]] || API_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[[ -n "$API_TOKEN" ]] || { read -rsp "API-токен панели: " API_TOKEN; echo; API_TOKEN="$(printf '%s' "$API_TOKEN" | tr -d '[:space:]')"; }
PORT=$(( 30000 + RANDOM % 20000 ))

RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" RW_MY_IP="$MY_IP" RW_PROFILE="${PROFILE_UUID:-}" \
RW_PORT="$PORT" python3 - "$WORK/cfg.json" <<'PYEOF'
import json, os, socket, sys, urllib.request
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
def api(path):
    req = urllib.request.Request(PANEL + path); req.add_header("Authorization", "Bearer " + TOK)
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode() or "{}"); return d.get("response", d)
def resolve(a):
    try: return {i[4][0] for i in socket.getaddrinfo(a, None, socket.AF_INET)}
    except Exception: return set()
uuid = os.environ["RW_PROFILE"]
if not uuid:
    nodes = api("/api/nodes"); nodes = nodes.get("nodes", nodes) if isinstance(nodes, dict) else nodes
    cand = [n for n in nodes or [] if (n.get("configProfile") or {}).get("activeConfigProfileUuid")]
    mine = [n for n in cand if os.environ["RW_MY_IP"] and os.environ["RW_MY_IP"] in resolve(n.get("address", ""))]
    if len(mine) != 1:
        for i, n in enumerate(cand, 1): print(f"  {i}) {n.get('name')}  {n.get('address')}", file=sys.stderr)
        sys.stderr.write("Номер ноды: "); sys.stderr.flush()
        mine = [cand[int(open("/dev/tty").readline().strip() or 1) - 1]]
    uuid = mine[0]["configProfile"]["activeConfigProfileUuid"]
    print(f"== Нода: {mine[0].get('name')} ({mine[0].get('address')})", file=sys.stderr)
cfg = api(f"/api/config-profiles/{uuid}")["config"]
outs = cfg.get("outbounds", []); rules = cfg.get("routing", {}).get("rules", [])
d = next((o for o in outs if o.get("tag") == "direct"), {})
print(f"   direct: domainStrategy={d.get('settings', {}).get('domainStrategy', 'AsIs')}", file=sys.stderr)
print(f"   outbounds: {', '.join(o.get('tag', '?') for o in outs)}", file=sys.stderr)
for r in rules:
    what = (f"{len(r['domain'])} доменов" if r.get("domain") else
            f"ip {r['ip']}" if r.get("ip") else f"protocol {r['protocol']}" if r.get("protocol") else
            f"inbound {r['inboundTag']}" if r.get("inboundTag") else "всё остальное")
    print(f"   правило: {what} -> {r.get('outboundTag')}", file=sys.stderr)
# тот же конфиг, но вход — локальный socks со sniffing, как у инбаундов ноды
test = {"log": {"loglevel": "warning"}, "dns": cfg.get("dns", {}),
        "inbounds": [{"tag": "diag", "listen": "127.0.0.1", "port": int(os.environ["RW_PORT"]),
                      "protocol": "socks", "settings": {"udp": True},
                      "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}}],
        "outbounds": outs,
        "routing": {"domainStrategy": cfg.get("routing", {}).get("domainStrategy", "AsIs"),
                    "rules": [r for r in rules if "inboundTag" not in r or r["inboundTag"] == ["dns-internal"]]}}
json.dump(test, open(sys.argv[1], "w"))
# какой outbound выберется для домена (грубо, только по domain:-правилам)
def route(host):
    for r in rules:
        for dm in r.get("domain", []):
            v = dm.split(":", 1)[1] if dm.startswith("domain:") else None
            if v and (host == v or host.endswith("." + v)): return r.get("outboundTag")
        if r.get("network") and "inboundTag" not in r: return r.get("outboundTag")
    return "direct"
json.dump({"route": {h: route(h) for h in ["www.google.com", "ya.ru", "gemini.google.com", "www.gstatic.com", "chatgpt.com", "www.youtube.com"]}},
          open(sys.argv[1] + ".routes", "w"))
PYEOF

docker rm -f rw-diag >/dev/null 2>&1 || true
docker run -d --name rw-diag --network host -v "$WORK/cfg.json:/diag.json:ro" \
  --entrypoint /usr/local/bin/xray "$NODE_IMAGE" run -c /diag.json >/dev/null
sleep 3
if ! docker ps --format '{{.Names}}' | grep -qx rw-diag; then
  echo "!! Временный Xray не запустился с конфигом профиля:"; docker logs rw-diag 2>&1 | tail -15; exit 1
fi
echo "== Через Xray с конфигом ноды"
for u in $URLS; do
  h=${u#https://}; h=${h%%/*}
  via=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['route'].get(sys.argv[2],'?'))" "$WORK/cfg.json.routes" "$h")
  r=$(curl -s -o /dev/null --max-time 12 --socks5-hostname "127.0.0.1:$PORT" \
       -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36' \
       -w '%{http_code} за %{time_total}s' "$u" || true)
  printf '  %-40s [%s] %s\n' "$u" "$via" "${r:-нет ответа}"
done
echo "== Ошибки Xray во время теста"
docker logs rw-diag 2>&1 | grep -iE 'error|fail|timeout' | tail -10 || true
