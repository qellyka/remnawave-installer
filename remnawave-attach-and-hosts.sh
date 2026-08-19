#!/usr/bin/env bash
# Attaches an existing 4-inbound Config Profile to an existing node, and
# creates one client-facing Host per inbound — by qellyka
#
# Standalone: no server/node access needed, works entirely through the API.
# Run this from anywhere that can reach your panel.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

read_panel_url() {
  local prompt="$1" __resultvar="$2" value
  read -rp "$prompt" value
  [[ "$value" =~ ^https?:// ]] || value="https://$value"
  printf -v "$__resultvar" '%s' "$value"
}

echo "==================================================="
echo "  Remnawave — attach profile + create hosts — by qellyka"
echo "==================================================="
read_panel_url "URL панели (panel.example.com или https://panel.example.com): " PANEL_URL
read -rp "API-токен: " API_TOKEN
[[ -n "$API_TOKEN" ]] || die "Токен обязателен"

apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl python3 >/dev/null 2>&1

cat > /tmp/remnawave_list_nodes.py <<'LISTEOF'
#!/usr/bin/env python3
import json, os, sys, urllib.request, urllib.error
PANEL_URL = os.environ.get("RW_PANEL_URL", "")
API_TOKEN = os.environ.get("RW_API_TOKEN", "")
req = urllib.request.Request(PANEL_URL.rstrip("/") + "/api/nodes", method="GET")
req.add_header("Authorization", f"Bearer {API_TOKEN}")
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
except (urllib.error.URLError, urllib.error.HTTPError) as e:
    print(f"[ERROR] Could not fetch node list: {e}", file=sys.stderr); sys.exit(1)
nodes = data.get("response", [])
if not nodes:
    print("[ERROR] No nodes found in this panel", file=sys.stderr); sys.exit(2)
for i, n in enumerate(nodes, start=1):
    connected = "connected" if n.get("isConnected") else "disconnected"
    print(f"{i}|{n['uuid']}|{n.get('name','?')}|{n.get('address','?')}|{connected}")
LISTEOF

cat > /tmp/remnawave_list_profiles.py <<'PROFEOF'
#!/usr/bin/env python3
import json, os, sys, urllib.request, urllib.error
PANEL_URL = os.environ.get("RW_PANEL_URL", "")
API_TOKEN = os.environ.get("RW_API_TOKEN", "")
req = urllib.request.Request(PANEL_URL.rstrip("/") + "/api/config-profiles", method="GET")
req.add_header("Authorization", f"Bearer {API_TOKEN}")
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
except (urllib.error.URLError, urllib.error.HTTPError) as e:
    print(f"[ERROR] Could not fetch config profiles: {e}", file=sys.stderr); sys.exit(1)
profiles = data.get("response", {}).get("configProfiles", [])
if not profiles:
    print("[ERROR] No config profiles found", file=sys.stderr); sys.exit(2)
for pi, p in enumerate(profiles, start=1):
    print(f"P|{pi}|{p['uuid']}|{p.get('name','?')}")
PROFEOF

log "Получаю список нод из панели..."
NODES_LIST=$(RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" python3 /tmp/remnawave_list_nodes.py) \
  || die "Не удалось получить список нод — проверь URL панели и токен"
echo ""
echo "Доступные ноды:"
echo "$NODES_LIST" | awk -F'|' '{printf "  %s) %s  [%s]  %s\n", $1, $3, $5, $4}'
echo ""
read -rp "Выбери номер ноды: " NODE_PICK
PICKED_NODE=$(echo "$NODES_LIST" | awk -F'|' -v n="$NODE_PICK" '$1==n')
[[ -n "$PICKED_NODE" ]] || die "Некорректный выбор"
NODE_UUID=$(echo "$PICKED_NODE" | cut -d'|' -f2)
log "Выбрана нода: $(echo "$PICKED_NODE" | cut -d'|' -f3) ($NODE_UUID)"

log "Получаю список Config Profiles из панели..."
PROFILES_LIST=$(RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" python3 /tmp/remnawave_list_profiles.py) \
  || die "Не удалось получить список профилей"
echo ""
echo "Доступные профили:"
echo "$PROFILES_LIST" | awk -F'|' '{printf "  %s) %s\n", $2, $4}'
echo ""
read -rp "Выбери номер профиля (тот, что с 4 базовыми инбаундами): " PROFILE_PICK
PICKED_PROFILE=$(echo "$PROFILES_LIST" | awk -F'|' -v n="$PROFILE_PICK" '$1=="P" && $2==n')
[[ -n "$PICKED_PROFILE" ]] || die "Некорректный выбор"
PROFILE_UUID=$(echo "$PICKED_PROFILE" | cut -d'|' -f3)
log "Выбран профиль: $(echo "$PICKED_PROFILE" | cut -d'|' -f4) ($PROFILE_UUID)"

echo ""
echo "Публичный адрес этой ноды — то, к чему реально будут подключаться клиенты"
echo "(домен или IP, не обязательно совпадает с адресом, который панель использует"
echo "для управления нодой)."
read -rp "Публичный адрес ноды: " NODE_PUBLIC_ADDRESS
[[ -n "$NODE_PUBLIC_ADDRESS" ]] || die "Адрес обязателен"

cat > /tmp/remnawave_attach_and_hosts.py <<'MAINEOF'
#!/usr/bin/env python3
"""
Remnawave — attach profile to node + create one Host per inbound — by qellyka
Reads the profile's own stored raw Xray config back via the API (rather than
asking the user to re-type values a previous, possibly-separate script run
already randomized) to get each inbound's real port/SNI/path, then builds a
Host per inbound with only the fields confirmed in CreateHostBodyDto's own
schema — nothing invented. Notably: Reality's public key is NOT a Host field
at all (the panel derives it server-side from the stored private key), so
none of this needs to touch key material a second time.
"""
import json
import os
import sys
import urllib.request
import urllib.error


def die(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)


def api(method, path, token, body=None):
    url = PANEL_URL.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode(errors="replace")
        die(f"{method} {path} -> HTTP {e.code}: {body_text}")
    except urllib.error.URLError as e:
        die(f"{method} {path} -> connection failed: {e}")


PANEL_URL = os.environ["RW_PANEL_URL"]
API_TOKEN = os.environ["RW_API_TOKEN"]
NODE_UUID = os.environ["RW_NODE_UUID"]
PROFILE_UUID = os.environ["RW_PROFILE_UUID"]
NODE_ADDRESS = os.environ["RW_NODE_PUBLIC_ADDRESS"]

print("[1/4] Verifying API token...")
api("GET", "/api/hosts", API_TOKEN)
print("      OK.")

print("[2/4] Reading profile's stored config + inbound UUIDs...")
profile_resp = api("GET", f"/api/config-profiles/{PROFILE_UUID}", API_TOKEN)["response"]
raw_config = profile_resp["config"]
tag_to_uuid = {ib["tag"]: ib["uuid"] for ib in profile_resp["inbounds"]}
raw_by_tag = {ib["tag"]: ib for ib in raw_config.get("inbounds", [])}

WANTED_TAGS = ["reality-tcp", "reality-grpc", "reality-xhttp", "hysteria2"]
missing = [t for t in WANTED_TAGS if t not in tag_to_uuid]
if missing:
    die(f"This profile is missing expected inbound(s): {missing}. "
        f"Found: {list(tag_to_uuid.keys())}")

print("[3/4] Attaching node to this profile (all 4 inbounds active)...")
node_body = {
    "uuid": NODE_UUID,
    "configProfile": {
        "activeConfigProfileUuid": PROFILE_UUID,
        "activeInbounds": [tag_to_uuid[t] for t in WANTED_TAGS]
    }
}
api("PATCH", "/api/nodes", API_TOKEN, node_body)
print("      Done.")

print("[4/4] Creating one Host per inbound...")
created = {}

# --- Reality + TCP ---
tcp_raw = raw_by_tag["reality-tcp"]
tcp_sni = tcp_raw["streamSettings"]["realitySettings"]["serverNames"][0]
host = api("POST", "/api/hosts", API_TOKEN, {
    "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid["reality-tcp"]},
    "remark": "Reality TCP",
    "address": NODE_ADDRESS,
    "port": tcp_raw["port"],
    "sni": tcp_sni,
    "fingerprint": "chrome",
    "securityLayer": "DEFAULT"
})["response"]
created["reality-tcp"] = {"port": tcp_raw["port"], "sni": tcp_sni, "host_uuid": host["uuid"]}
print(f"      reality-tcp   -> Host {host['uuid']}")

# --- Reality + gRPC ---
grpc_raw = raw_by_tag["reality-grpc"]
grpc_sni = grpc_raw["streamSettings"]["realitySettings"]["serverNames"][0]
grpc_service = grpc_raw["streamSettings"]["grpcSettings"]["serviceName"]
host = api("POST", "/api/hosts", API_TOKEN, {
    "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid["reality-grpc"]},
    "remark": "Reality gRPC",
    "address": NODE_ADDRESS,
    "port": grpc_raw["port"],
    "sni": grpc_sni,
    "path": grpc_service,
    "alpn": "h2",
    "fingerprint": "chrome",
    "securityLayer": "DEFAULT"
})["response"]
created["reality-grpc"] = {"port": grpc_raw["port"], "sni": grpc_sni, "serviceName": grpc_service, "host_uuid": host["uuid"]}
print(f"      reality-grpc  -> Host {host['uuid']}")

# --- Reality + XHTTP ---
xhttp_raw = raw_by_tag["reality-xhttp"]
xhttp_sni = xhttp_raw["streamSettings"]["realitySettings"]["serverNames"][0]
xhttp_path = xhttp_raw["streamSettings"]["xhttpSettings"]["path"]
host = api("POST", "/api/hosts", API_TOKEN, {
    "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid["reality-xhttp"]},
    "remark": "Reality XHTTP",
    "address": NODE_ADDRESS,
    "port": xhttp_raw["port"],
    "sni": xhttp_sni,
    "path": xhttp_path,
    "alpn": "h2,http/1.1",
    "fingerprint": "chrome",
    "securityLayer": "DEFAULT"
})["response"]
created["reality-xhttp"] = {"port": xhttp_raw["port"], "sni": xhttp_sni, "path": xhttp_path, "host_uuid": host["uuid"]}
print(f"      reality-xhttp -> Host {host['uuid']}")

# --- Hysteria2 ---
hy2_raw = raw_by_tag["hysteria2"]
host = api("POST", "/api/hosts", API_TOKEN, {
    "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid["hysteria2"]},
    "remark": "Hysteria2",
    "address": NODE_ADDRESS,
    "port": hy2_raw["port"],
    "sni": "www.bing.com",
    "securityLayer": "DEFAULT"
})["response"]
created["hysteria2"] = {"port": hy2_raw["port"], "sni": "www.bing.com", "host_uuid": host["uuid"]}
print(f"      hysteria2     -> Host {host['uuid']}")

print()
print("=====================================================")
print("Done. Node attached, 4 hosts created:")
for tag, info in created.items():
    print(f"  {tag}: {json.dumps(info)}")
print()
print("Hysteria2 uses a self-signed cert — clients need either allowInsecure=1")
print("or a pinned cert hash (Host.pinnedPeerCertSha256, not set here — this")
print("script doesn't have access to the actual cert bytes to derive it; add")
print("it by hand in the panel UI if you want that instead of allowInsecure).")
print("PLEASE open the panel UI and visually confirm everything looks correct.")
print("=====================================================")
MAINEOF

RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" RW_NODE_UUID="$NODE_UUID" \
  RW_PROFILE_UUID="$PROFILE_UUID" RW_NODE_PUBLIC_ADDRESS="$NODE_PUBLIC_ADDRESS" \
  python3 /tmp/remnawave_attach_and_hosts.py
