#!/usr/bin/env bash
# =============================================================================
#  warp-domains.sh — поменять список доменов, идущих через WARP, на УЖЕ установленной ноде
#  (WARP в режиме «выбранные сервисы»). Правит только правило с outbound "warp".
#     bash warp-domains.sh list            — показать текущие домены
#     bash warp-domains.sh gemini          — добавить полный набор доменов Gemini/Google AI
#     bash warp-domains.sh add a.com,b.com — добавить свои
#     bash warp-domains.sh del a.com,b.com — убрать
#  Переменные: PANEL_URL, API_TOKEN (токен берётся из /root/.rw_node_token, если есть)
# =============================================================================
set -euo pipefail
TOKEN_FILE="/root/.rw_node_token"
GEMINI="gemini.google.com,gemini.google,bard.google.com,aistudio.google.com,makersuite.google.com,ai.google.dev,generativelanguage.googleapis.com,notebooklm.google.com,notebooklm.google,labs.google,deepmind.google,clients6.google.com,jnn-pa.googleapis.com,accounts.google.com,gstatic.com,googleusercontent.com,apis.google.com,ogs.google.com,play.google.com"
CMD="${1:-list}"; ARG="${2:-}"
case "$CMD" in gemini) CMD=add; ARG="$GEMINI" ;; list) ;; add|del) [[ -n "$ARG" ]] || { echo "Нужен список доменов через запятую"; exit 1; } ;; *) echo "Команды: list | gemini | add d1,d2 | del d1,d2"; exit 1 ;; esac
PANEL_URL="${PANEL_URL:-}"
[[ -n "$PANEL_URL" ]] || read -rp "URL панели (panel.example.com): " PANEL_URL
PANEL_URL="$(printf '%s' "$PANEL_URL" | tr -d '[:space:]')"; PANEL_URL="${PANEL_URL%/}"
[[ "$PANEL_URL" == http* ]] || PANEL_URL="https://$PANEL_URL"
API_TOKEN="${API_TOKEN:-}"
[[ -n "$API_TOKEN" || ! -s "$TOKEN_FILE" ]] || API_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[[ -n "$API_TOKEN" ]] || { read -rsp "API-токен панели: " API_TOKEN; echo; API_TOKEN="$(printf '%s' "$API_TOKEN" | tr -d '[:space:]')"; }
RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" RW_CMD="$CMD" RW_ARG="$ARG" RW_PROFILE="${PROFILE_UUID:-}" python3 - <<'PYEOF'
import json, os, sys, urllib.request
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PANEL + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOK); req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode() or "{}"); return d.get("response", d)
profs = api("GET", "/api/config-profiles")
profs = profs.get("configProfiles", profs) if isinstance(profs, dict) else profs
found = []
for p in profs or []:
    if os.environ["RW_PROFILE"] and p["uuid"] != os.environ["RW_PROFILE"]: continue
    cfg = api("GET", f"/api/config-profiles/{p['uuid']}").get("config") or {}
    if any(o.get("tag") == "warp" for o in cfg.get("outbounds", [])): found.append((p, cfg))
if not found: sys.exit("В панели нет профиля с outbound «warp».")
if len(found) > 1:
    for i, (p, _) in enumerate(found, 1): print(f"  {i}) {p.get('name')}  {p['uuid']}")
    n = int(input("Номер профиля: ") or 1); found = [found[n - 1]]
p, cfg = found[0]
rule = next((r for r in cfg.get("routing", {}).get("rules", []) if r.get("outboundTag") == "warp" and r.get("domain")), None)
if rule is None:
    sys.exit("Правила «домены → warp» нет: WARP, видимо, в режиме «весь трафик» (тогда через него и так идёт всё).")
cur = rule["domain"]; cmd = os.environ["RW_CMD"]
norm = lambda d: d if ":" in d else f"domain:{d}"
want = [norm(x) for x in os.environ["RW_ARG"].split(",") if x.strip()]
if cmd == "list":
    print(f"Профиль: {p.get('name')}\nЧерез WARP идут ({len(cur)}):"); print("  " + "\n  ".join(cur)); sys.exit(0)
new = cur + [d for d in want if d not in cur] if cmd == "add" else [d for d in cur if d not in want]
if new == cur: print("Ничего не изменилось."); sys.exit(0)
rule["domain"] = new
api("PATCH", "/api/config-profiles", {"uuid": p["uuid"], "config": cfg})
print(f"Готово: было {len(cur)}, стало {len(new)} доменов. Нода применит конфиг сама (перезапуск Xray на ней — секунды).")
PYEOF
