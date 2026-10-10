#!/usr/bin/env bash
# =============================================================================
#  warp-rotate.sh — сменить WARP-аккаунт / IP на УЖЕ установленной ноде Remnawave
#
#  Регистрирует новый WARP-аккаунт, проверяет через временный Xray из образа ноды
#  страну выхода и доступность Google (gemini.google.com), и только с хорошим
#  результатом подменяет outbound "warp" в профиле ноды через API панели.
#  Правила маршрутизации и всё остальное в профиле не трогаются.
#  Запускать на сервере с нодой:
#     bash <(curl -fsSL https://raw.githubusercontent.com/qellyka/remnawave-installer/main/warp-rotate.sh)
#  Переменные: PANEL_URL, API_TOKEN, WANT_LOC=PL, TRIES=6, GOOGLE_CHECK=0|1
# =============================================================================
set -euo pipefail

NODE_DIR="${NODE_DIR:-/opt/remnanode}"
TOKEN_FILE="/root/.rw_node_token"
WARP_FILE="$NODE_DIR/warp.json"
TRIES="${TRIES:-6}"
GOOGLE_CHECK="${GOOGLE_CHECK:-1}"
WARP_ENDPOINTS=("162.159.192.1:2408" "162.159.193.1:2408" "162.159.195.1:2408" "188.114.96.1:2408" "188.114.97.1:2408")

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[38;5;203m'
  C_GRN=$'\033[38;5;114m'; C_YEL=$'\033[38;5;221m'; C_CYN=$'\033[38;5;80m'; C_MAG=$'\033[38;5;177m'
else C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_MAG=""; fi
log()  { printf '  %s›%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s⚠ %s%s\n' "$C_YEL" "$*" "$C_RST"; }
die()  { printf '\n  %s%s✗ %s%s\n' "$C_RED" "$C_B" "$*" "$C_RST" >&2; exit 1; }
Q="  ${C_MAG}?${C_RST} "

# --- функции регистрации и сборки outbound — те же, что в remnanode-deploy.sh ---
warp_register() {
  openssl genpkey -algorithm X25519 -out "$WORK_DIR/wg.key" 2>/dev/null || return 1
  local priv pub
  priv=$(openssl pkey -in "$WORK_DIR/wg.key" -outform DER | tail -c 32 | base64)
  pub=$(openssl pkey -in "$WORK_DIR/wg.key" -pubout -outform DER | tail -c 32 | base64)
  rm -f "$WORK_DIR/wg.key"
  WARP_PRIV="$priv" WARP_PUB="$pub" python3 - "$WARP_FILE" <<'WREGEOF'
import base64, datetime, json, os, sys, urllib.error, urllib.request
OUT = sys.argv[1]
APIS = ["https://api.cloudflareclient.com/v0a2158",
        "https://api.cloudflareclient.com/v0i1909051800"]
def call(url, method="GET", body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json; charset=UTF-8")
    req.add_header("User-Agent", "okhttp/3.12.1")
    req.add_header("CF-Client-Version", "a-6.10-2158")
    if token: req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode())
def unwrap(d): return d.get("result", d) if isinstance(d, dict) else d
tos = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
body = {"key": os.environ["WARP_PUB"], "install_id": "", "fcm_token": "", "tos": tos,
        "model": "PC", "type": "Android", "locale": "en_US"}
last = ""
import time
def reg_post(api):
    # Cloudflare периодически отдаёт 5xx на регистрацию — до 3 попыток.
    for i in range(3):
        try:
            return unwrap(call(api + "/reg", "POST", body))
        except urllib.error.HTTPError as e:
            if e.code < 500 or i == 2: raise
            time.sleep(3)
for api in APIS:
    try:
        reg = reg_post(api)
        rid, tok = reg["id"], reg["token"]
        try: call(f"{api}/reg/{rid}", "PATCH", {"warp_enabled": True}, tok)
        except Exception: pass
        cfg = reg.get("config") or unwrap(call(f"{api}/reg/{rid}", "GET", None, tok)).get("config")
        peer = cfg["peers"][0]; addr = cfg["interface"]["addresses"]
        cid = cfg.get("client_id") or ""
        reserved = list(base64.b64decode(cid))[:3] if cid else [0, 0, 0]
        out = {"id": rid, "token": tok, "api": api, "privateKey": os.environ["WARP_PRIV"],
               "peerPublicKey": peer["public_key"], "v4": addr["v4"], "v6": addr["v6"],
               "reserved": reserved}
        old = os.umask(0o077)
        json.dump(out, open(OUT, "w")); os.umask(old)
        sys.exit(0)
    except urllib.error.HTTPError as e:
        last = f"{api}: HTTP {e.code} {e.read().decode(errors='replace')[:200]}"
    except Exception as e:
        last = f"{api}: {e}"
print(last, file=sys.stderr); sys.exit(1)
WREGEOF
}

# $1 endpoint, $2 файл для outbound-JSON (тег "warp")
warp_outbound() {
  python3 - "$WARP_FILE" "$1" > "$2" <<'WOBEOF'
import json, sys
w = json.load(open(sys.argv[1]))
print(json.dumps({
    "tag": "warp", "protocol": "wireguard",
    "settings": {
        "secretKey": w["privateKey"],
        "address": [w["v4"] + "/32", w["v6"] + "/128"],
        "peers": [{"publicKey": w["peerPublicKey"],
                   "allowedIPs": ["0.0.0.0/0", "::/0"],
                   "endpoint": sys.argv[2]}],
        "reserved": w["reserved"], "mtu": 1280,
        # Userspace-стек: без него Xray в контейнере пытается писать rp_filter
        # в read-only /proc/sys и падает целиком — нода ложится.
        "noKernelTun": True,
        "domainStrategy": "ForceIPv4v6"}}))
WOBEOF
}


# $1 endpoint -> печатает "LOC IP GOOGLE_CODE" или ничего, если WARP не поднялся
warp_probe() {
  local ep="$1" port=$(( 30000 + RANDOM % 20000 )) tr g="-"
  warp_outbound "$ep" "$WORK_DIR/warp-ob.json" || return 0
  python3 - "$WORK_DIR/warp-ob.json" "$port" > "$WORK_DIR/warp-test.json" <<'WTEOF'
import json, sys
print(json.dumps({"log": {"loglevel": "warning"},
    "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks",
                  "settings": {"udp": True}}],
    "outbounds": [json.load(open(sys.argv[1]))]}))
WTEOF
  docker rm -f rw-warp-test >/dev/null 2>&1 || true
  docker run -d --rm --name rw-warp-test --network host \
    -v "$WORK_DIR/warp-test.json:/warp-test.json:ro" \
    --entrypoint /usr/local/bin/xray "$NODE_IMAGE" run -c /warp-test.json >/dev/null 2>&1 || return 0
  sleep 3
  tr=$(curl -s --max-time 12 --socks5-hostname "127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace || true)
  if grep -qE '^warp=(on|plus)' <<<"$tr" && [[ "$GOOGLE_CHECK" == "1" ]]; then
    g=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --socks5-hostname "127.0.0.1:$port" \
        -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36' \
        https://gemini.google.com/app || true)
  fi
  docker rm -f rw-warp-test >/dev/null 2>&1 || true
  grep -qE '^warp=(on|plus)' <<<"$tr" || return 0
  echo "$(grep '^loc=' <<<"$tr" | cut -d= -f2) $(grep '^ip=' <<<"$tr" | cut -d= -f2) $g"
}

# ------------------------------ работа с панелью ------------------------------
write_helpers() {
cat > "$WORK_DIR/panel.py" <<'PANELEOF'
import json, os, sys, urllib.request, urllib.error
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PANEL + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOK)
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode() or "{}"); return d.get("response", d)
cmd = sys.argv[1]
if cmd == "find":      # профили, в которых есть outbound "warp": idx|uuid|name|страна ноды
    profs = api("GET", "/api/config-profiles")
    profs = profs.get("configProfiles", profs) if isinstance(profs, dict) else profs
    nodes = api("GET", "/api/nodes"); nodes = nodes.get("nodes", nodes) if isinstance(nodes, dict) else nodes
    i = 0
    for p in profs or []:
        cfg = (api("GET", f"/api/config-profiles/{p['uuid']}").get("config") or {})
        if not any(o.get("tag") == "warp" for o in cfg.get("outbounds", [])): continue
        n = next((n for n in nodes or [] if (n.get("configProfile") or {}).get("activeConfigProfileUuid") == p["uuid"]), None)
        cc = ((n or {}).get("countryCode") or "").upper()
        i += 1; print(f"{i}|{p['uuid']}|{p.get('name')}|{'' if cc == 'XX' else cc}")
elif cmd == "apply":   # apply <profile_uuid> <outbound.json> <prev_out.json>
    uuid, newf, prevf = sys.argv[2:5]
    prof = api("GET", f"/api/config-profiles/{uuid}"); cfg = prof["config"]
    new = json.load(open(newf)); outs = cfg.get("outbounds", [])
    idx = next(i for i, o in enumerate(outs) if o.get("tag") == "warp")
    json.dump(outs[idx], open(prevf, "w")); outs[idx] = new
    api("PATCH", "/api/config-profiles", {"uuid": uuid, "config": cfg})
PANELEOF
}

main() {
  [[ $EUID -eq 0 ]] || die "Запускай от root."
  for c in curl python3 openssl docker; do command -v "$c" >/dev/null 2>&1 || die "Нужен $c"; done
  WORK_DIR="$(mktemp -d /tmp/rw-warp.XXXXXX)"; chmod 700 "$WORK_DIR"
  trap 'docker rm -f rw-warp-test >/dev/null 2>&1; rm -rf "$WORK_DIR"' EXIT
  printf '\n  %s%sWARP: смена аккаунта на установленной ноде%s\n\n' "$C_B" "$C_MAG" "$C_RST"

  NODE_IMAGE=$(grep -oE 'image:[[:space:]]*[^[:space:]]+' "$NODE_DIR/docker-compose.yml" 2>/dev/null | head -1 | awk '{print $2}' || true)
  NODE_IMAGE="${NODE_IMAGE:-ghcr.io/remnawave/node:latest}"
  docker image inspect "$NODE_IMAGE" >/dev/null 2>&1 || docker pull "$NODE_IMAGE" >/dev/null 2>&1 || die "Нет образа ноды $NODE_IMAGE"

  # --- панель ---
  PANEL_URL="${PANEL_URL:-}"
  [[ -n "$PANEL_URL" ]] || read -rp "${Q}URL панели (panel.example.com): " PANEL_URL
  PANEL_URL="$(printf '%s' "$PANEL_URL" | tr -d '[:space:]')"; PANEL_URL="${PANEL_URL%/}"
  [[ "$PANEL_URL" == http* ]] || PANEL_URL="https://$PANEL_URL"
  API_TOKEN="${API_TOKEN:-}"
  [[ -n "$API_TOKEN" || ! -s "$TOKEN_FILE" ]] || { API_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"; log "Использую сохранённый API-токен."; }
  [[ -n "$API_TOKEN" ]] || { read -rsp "${Q}API-токен панели: " API_TOKEN; echo; API_TOKEN="$(printf '%s' "$API_TOKEN" | tr -d '[:space:]')"; }
  export RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN"
  write_helpers

  PROFILES=$(python3 "$WORK_DIR/panel.py" find 2>"$WORK_DIR/err") || die "Панель не ответила: $(tail -n 2 "$WORK_DIR/err")"
  [[ -n "$PROFILES" ]] || die "В панели нет профиля с outbound «warp» — WARP на этой установке не включался."
  if [[ "$(grep -c . <<<"$PROFILES")" -gt 1 ]]; then
    echo "  Профили с WARP:"
    while IFS="|" read -r n _ name cc; do printf "    %s) %s %s[%s]%s\n" "$n" "$name" "$C_DIM" "${cc:-?}" "$C_RST"; done <<<"$PROFILES"
    read -rp "${Q}Номер профиля [1]: " PN; PN="${PN:-1}"
  else PN=1; fi
  ROW=$(sed -n "${PN}p" <<<"$PROFILES"); [[ -n "$ROW" ]] || die "Нет профиля с номером $PN"
  IFS='|' read -r _ PROF_UUID PROF_NAME PROF_CC <<<"$ROW"
  ok "Профиль: $PROF_NAME"

  WANT_LOC="${WANT_LOC:-$PROF_CC}"
  [[ "$WANT_LOC" =~ ^[A-Z]{2}$ ]] || WANT_LOC=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace | grep '^loc=' | cut -d= -f2 || true)
  log "Нужна страна выхода WARP: ${WANT_LOC:-любая}; проверка Google: $([[ "$GOOGLE_CHECK" == "1" ]] && echo да || echo нет)"

  [[ -s "$WARP_FILE" ]] && cp -p "$WARP_FILE" "$WARP_FILE.bak"
  GOT=""; BEST=""
  for try in $(seq 1 "$TRIES"); do
    log "Попытка $try/$TRIES: регистрирую новый аккаунт..."
    if ! warp_register; then warn "Регистрация не удалась (Cloudflare API недоступен или отказал)."; sleep 3; continue; fi
    for ep in "${WARP_ENDPOINTS[@]}"; do
      res=$(warp_probe "$ep") || res=""
      [[ -n "$res" ]] || { log "  $ep — WARP не поднялся"; continue; }
      read -r loc wip g <<<"$res"
      log "  $ep — выход $loc ($wip)${g:+, Google: $g}"
      good=true
      [[ -n "$WANT_LOC" && "$loc" != "$WANT_LOC" ]] && good=false
      [[ "${g:--}" == "403" || "${g:--}" == "451" || "${g:--}" == "000" ]] && good=false
      if [[ "$good" == "true" ]]; then GOT="$ep|$loc|$wip|$g"; break 2; fi
      [[ -z "$BEST" && ( -z "$WANT_LOC" || "$loc" == "$WANT_LOC" ) ]] && { BEST="$ep|$loc|$wip|$g"; cp "$WARP_FILE" "$WORK_DIR/best.json"; }
      break    # эндпоинты одного аккаунта дают тот же IP-пул — меняем аккаунт
    done
  done
  if [[ -z "$GOT" ]]; then
    warn "Подходящий IP за $TRIES попыток не найден."
    [[ -n "$BEST" ]] || die "Ни один аккаунт не дал нужной страны. Ничего не изменено."
    IFS='|' read -r _ bl bw bg <<<"$BEST"
    read -rp "${Q}Взять лучший из найденных (выход $bl, $bw, Google: ${bg:--})? [y/N]: " yn
    [[ "$yn" =~ ^[YyДдУу]$ ]] || die "Отменено, ничего не изменено."
    cp "$WORK_DIR/best.json" "$WARP_FILE"; GOT="$BEST"
  fi
  IFS='|' read -r EP LOC WIP GC <<<"$GOT"
  warp_outbound "$EP" "$WORK_DIR/new-outbound.json"

  python3 "$WORK_DIR/panel.py" apply "$PROF_UUID" "$WORK_DIR/new-outbound.json" "$NODE_DIR/warp-outbound.prev.json" \
    2>"$WORK_DIR/err" || { [[ -s "$WARP_FILE.bak" ]] && cp -p "$WARP_FILE.bak" "$WARP_FILE"; die "Не удалось обновить профиль: $(tail -n 2 "$WORK_DIR/err")"; }
  chmod 600 "$NODE_DIR/warp-outbound.prev.json" 2>/dev/null || true
  printf '\n  %s%s✓ Готово: WARP заменён%s\n' "$C_GRN" "$C_B" "$C_RST"
  printf '  %s│%s новый выход  %s (%s), эндпоинт %s\n' "$C_DIM" "$C_RST" "$LOC" "$WIP" "$EP"
  [[ -n "$GC" ]] && printf '  %s│%s Google       код %s\n' "$C_DIM" "$C_RST" "$GC"
  printf '  %s│%s прошлый outbound сохранён: %s/warp-outbound.prev.json\n' "$C_DIM" "$C_RST" "$NODE_DIR"
  printf '  %s╰─%s панель применяет профиль на ноде сама; если нет — Restart у ноды в панели.\n\n' "$C_DIM" "$C_RST"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
