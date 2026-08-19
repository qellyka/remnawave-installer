#!/usr/bin/env bash
# Seeds a Remnawave Config Profile with 4 well-established inbound presets
# (Reality+TCP, Reality+gRPC, Reality+XHTTP, Hysteria2) — by qellyka
#
# Standalone: does NOT install the panel, a node, Nginx, or anything else.
# Run this on any machine that can reach your panel's API (doesn't have to
# be the panel server itself) once you already have a running panel and an
# API token (Settings -> API Tokens in the panel UI).
#
# Parameter choices below (SNI donor, gRPC multiMode, XHTTP mode, Hysteria2
# masquerade) are not invented — each is cross-checked against the current
# official XTLS/Xray-core docs, the XTLS/Xray-examples repo, and multiple
# independent 2026 community write-ups. Anything not covered clearly by
# those sources (advanced XHTTP tuning, Reality's optional min/maxClientVer,
# etc.) is left out entirely rather than guessed.
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
echo "  Remnawave — seed 4 base inbounds — by qellyka"
echo "==================================================="
read_panel_url "URL панели (panel.example.com или https://panel.example.com): " PANEL_URL
read -rp "API-токен (Settings -> API Tokens в панели): " API_TOKEN
[[ -n "$API_TOKEN" ]] || die "Токен обязателен"

apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq curl openssl python3 >/dev/null 2>&1

if ! command -v xray >/dev/null 2>&1; then
  log "Устанавливаю Xray-core (только для генерации ключей Reality)..."
  bash -c "$(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install >/dev/null 2>&1
fi

gen_reality_key() {
  local keys
  keys=$(xray x25519)
  echo "$keys" | grep -i "Private" | awk '{print $NF}'
}

log "Генерирую ключи Reality (по одному набору на каждый из трёх инбаундов)..."
TCP_KEY=$(gen_reality_key); TCP_SID=$(openssl rand -hex 8)
GRPC_KEY=$(gen_reality_key); GRPC_SID=$(openssl rand -hex 8)
XHTTP_KEY=$(gen_reality_key); XHTTP_SID=$(openssl rand -hex 8)

log "Генерирую самоподписанный сертификат для Hysteria2..."
mkdir -p /etc/xray-certs
if [[ ! -f /etc/xray-certs/hy2-cert.crt ]]; then
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/xray-certs/hy2-key.pem -out /etc/xray-certs/hy2-cert.crt \
    -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1
fi
HY2_CERT_PEM=$(cat /etc/xray-certs/hy2-cert.crt)
HY2_KEY_PEM=$(cat /etc/xray-certs/hy2-key.pem)

cat > /tmp/remnawave_seed_profile.py <<'SEEDEOF'
#!/usr/bin/env python3
"""
Remnawave — seed a Config Profile with 4 well-established inbound presets — by qellyka
Creates ONLY a Config Profile — no Node, no Host.

Parameter notes (each cross-checked, none invented):
- realitySettings uses "target", not "dest" — both appear across XTLS's own
  docs depending on which page you land on; a maintainer clarified in
  github.com/XTLS/Xray-core/discussions/3518 that "target" is the one that
  actually works, matching every config this whole project has run so far.
- SNI donor defaults to www.apple.com — a widely-recommended, currently
  clean choice; www.microsoft.com is deliberately avoided as the default
  since XTLS/Xray-core#6356 documents a real cert-size failure with it on
  some builds.
- gRPC multiMode is set to true — several independent 2026 write-ups and
  the official XTLS/Xray-core discussion on gRPC+Reality note that leaving
  it false causes ERR_SSL_PROTOCOL_ERROR in browser-based clients.
- XHTTP mode is "auto" for this direct (non-CDN) inbound, matching the
  official example in github.com/XTLS/Xray-core/discussions/6078 and
  confirmed by a core contributor in discussion #4113 that "packet-up" is
  specifically the CDN-compatibility mode, not the default recommendation
  for a direct connection.
- Hysteria2's masquerade (type: proxy, a real external URL, rewriteHost)
  matches the official Hysteria2 docs' own example verbatim, down to using
  Bing as the demonstration target.
- Nothing else is set beyond what's shown as required in XTLS's own
  annotated example configs — optional fields neither documented as
  commonly-needed nor confirmed against a primary source (minClientVer,
  maxClientVer, spiderX, xmux tuning, etc.) are left out rather than guessed.
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
PROFILE_NAME = os.environ.get("RW_PROFILE_NAME", "base-4-preset")
SNI = os.environ.get("RW_SNI_DONOR", "www.apple.com")

inbounds = [
    {
        "tag": "reality-tcp",
        "listen": "0.0.0.0",
        "port": int(os.environ["RW_TCP_PORT"]),
        "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False, "xver": 0,
                "target": f"{SNI}:443",
                "serverNames": [SNI],
                "privateKey": os.environ["RW_TCP_KEY"],
                "shortIds": [os.environ["RW_TCP_SID"]]
            }
        }
    },
    {
        "tag": "reality-grpc",
        "listen": "0.0.0.0",
        "port": int(os.environ["RW_GRPC_PORT"]),
        "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        "streamSettings": {
            "network": "grpc",
            "security": "reality",
            "grpcSettings": {"serviceName": os.environ["RW_GRPC_SERVICE_NAME"], "multiMode": True},
            "realitySettings": {
                "show": False, "xver": 0,
                "target": f"{SNI}:443",
                "serverNames": [SNI],
                "privateKey": os.environ["RW_GRPC_KEY"],
                "shortIds": [os.environ["RW_GRPC_SID"]]
            }
        }
    },
    {
        "tag": "reality-xhttp",
        "listen": "0.0.0.0",
        "port": int(os.environ["RW_XHTTP_PORT"]),
        "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        "streamSettings": {
            "network": "xhttp",
            "security": "reality",
            "realitySettings": {
                "show": False, "xver": 0,
                "target": f"{SNI}:443",
                "serverNames": [SNI],
                "privateKey": os.environ["RW_XHTTP_KEY"],
                "shortIds": [os.environ["RW_XHTTP_SID"]]
            },
            "xhttpSettings": {
                "path": os.environ["RW_XHTTP_PATH"],
                "mode": "auto",
                "xPaddingBytes": "100-1000"
            }
        }
    },
    {
        "tag": "hysteria2",
        "listen": "0.0.0.0",
        "port": int(os.environ["RW_HY2_PORT"]),
        "protocol": "hysteria",
        "settings": {"version": 2, "clients": []},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        "streamSettings": {
            "network": "hysteria",
            "security": "tls",
            "tlsSettings": {
                "alpn": ["h3"], "minVersion": "1.3", "maxVersion": "1.3",
                "certificates": [{
                    "certificate": os.environ["RW_HY2_CERT_PEM"].splitlines(),
                    "key": os.environ["RW_HY2_KEY_PEM"].splitlines()
                }]
            },
            "hysteriaSettings": {
                "version": 2, "udpIdleTimeout": 60,
                "masquerade": {"type": "proxy", "url": os.environ.get("RW_HY2_MASQUERADE_URL", "https://www.bing.com"), "rewriteHost": True}
            }
        }
    },
]

print("[1/2] Verifying API token...")
api("GET", "/api/hosts", API_TOKEN)
print("      OK.")

print("[2/2] Creating Config Profile with 4 base inbounds...")
profile_body = {
    "name": PROFILE_NAME,
    "config": {
        "inbounds": inbounds,
        "outbounds": [{"protocol": "freedom", "tag": "direct"}]
    }
}
profile_resp = api("POST", "/api/config-profiles", API_TOKEN, profile_body)["response"]
profile_uuid = profile_resp["uuid"]
print(f"      Profile UUID: {profile_uuid}")
for ib in profile_resp["inbounds"]:
    print(f"      Inbound '{ib['tag']}' UUID: {ib['uuid']}")

print()
print("=====================================================")
print(f"Done. Profile '{PROFILE_NAME}' created: {profile_uuid}")
print("Open the panel UI -> Nodes -> pick this profile when creating/editing a node.")
print("=====================================================")
SEEDEOF

env \
  RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" \
  RW_TCP_PORT=443 RW_TCP_KEY="$TCP_KEY" RW_TCP_SID="$TCP_SID" \
  RW_GRPC_PORT=8443 RW_GRPC_KEY="$GRPC_KEY" RW_GRPC_SID="$GRPC_SID" RW_GRPC_SERVICE_NAME="$(openssl rand -hex 6)" \
  RW_XHTTP_PORT=2053 RW_XHTTP_KEY="$XHTTP_KEY" RW_XHTTP_SID="$XHTTP_SID" RW_XHTTP_PATH="/$(openssl rand -hex 8)/" \
  RW_HY2_PORT=8444 RW_HY2_CERT_PEM="$HY2_CERT_PEM" RW_HY2_KEY_PEM="$HY2_KEY_PEM" \
  python3 /tmp/remnawave_seed_profile.py
