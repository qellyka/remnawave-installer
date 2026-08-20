#!/usr/bin/env bash
# Seeds a Remnawave Config Profile with 3 well-established, shareable Reality
# presets (TCP, gRPC, XHTTP) — by qellyka
#
# Hysteria2 is deliberately NOT here — it fundamentally needs its own domain
# and certificate per node (that's how the protocol works, not optional),
# so it can't be part of a profile meant to be reused across many nodes.
# It's created separately, per node, by remnawave-attach-and-hosts.sh —
# along with the Nginx it needs and an optional CDN inbound.
#
# Standalone: does NOT install the panel, a node, Nginx, or anything else.
# Run this on any machine that can reach your panel's API (doesn't have to
# be the panel server itself) once you already have a running panel and an
# API token (Settings -> API Tokens in the panel UI).
#
# Parameter choices below (SNI donor, gRPC multiMode, XHTTP mode) are not
# invented — each is cross-checked against the current official XTLS/Xray-core
# docs, the XTLS/Xray-examples repo, and multiple independent 2026 community
# write-ups. Anything not covered clearly by those sources is left out rather
# than guessed.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# Freshly-provisioned servers very often hold the dpkg/apt lock for the first
# few minutes (cloud-init, unattended-upgrades, apt-daily.timer running in
# the background) — a plain `apt-get install` just hangs silently waiting for
# it, especially with output redirected away, and looks exactly like the
# script died. Wait for it explicitly instead, with a visible message.
wait_for_apt_lock() {
  local waited=0 max_wait=300
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if [[ $waited -eq 0 ]]; then
      warn "apt/dpkg занят другим процессом (часто бывает сразу после установки сервера — cloud-init/автообновления). Жду..."
    fi
    sleep 5
    waited=$((waited + 5))
    if [[ $waited -ge $max_wait ]]; then
      die "apt/dpkg занят другим процессом больше 5 минут — проверь вручную: ps aux | grep -i apt"
    fi
  done
  [[ $waited -gt 0 ]] && log "Дождался освобождения apt/dpkg (${waited}s)."
  return 0
}

read_panel_url() {
  local prompt="$1" __resultvar="$2" value
  read -rp "$prompt" value
  [[ "$value" =~ ^https?:// ]] || value="https://$value"
  printf -v "$__resultvar" '%s' "$value"
}

echo "==================================================="
echo "  Remnawave — seed shared inbounds (Reality x3) — by qellyka"
echo "==================================================="
read_panel_url "URL панели (panel.example.com или https://panel.example.com): " PANEL_URL
read -rp "API-токен (Settings -> API Tokens в панели): " API_TOKEN
[[ -n "$API_TOKEN" ]] || die "Токен обязателен"

wait_for_apt_lock
apt-get update -qq || true
wait_for_apt_lock
apt-get install -y -qq curl openssl python3 tar

if ! command -v xray >/dev/null 2>&1; then
  log "Устанавливаю Xray-core (только для генерации ключей Reality)..."
  bash -c "$(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" @ install
fi

# Verifies a small, curated list of SNI-donor candidates with RealiTLScanner
# (the official XTLS tool for exactly this) instead of trusting one hardcoded
# domain blindly. Deliberately narrow, not a broad scan: the tool's own docs
# warn that scanning wide ranges FROM the VPS itself risks getting that VPS's
# IP flagged — so this only checks a handful of specific, well-known,
# already-reasonable candidates, picking the first one confirmed reachable
# and TLS-1.3/H2-capable from THIS server's actual network position. Falls
# back to the static default below if the scanner can't be fetched/run for
# any reason — this is a nice-to-have verification, not a hard dependency.
SNI_CANDIDATES=("www.apple.com" "www.cloudflare.com" "swift.org")
SNI_DONOR="${SNI_CANDIDATES[0]}"

log "Пробую подтвердить SNI-донора через RealiTLScanner (официальный инструмент XTLS)..."
SCANNER_BIN=""
if RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/XTLS/RealiTLScanner/releases/latest 2>/dev/null); then
  ASSET_URL=$(echo "$RELEASE_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for a in data.get('assets', []):
        n = a['name'].lower()
        if 'linux' in n and ('amd64' in n or 'x86_64' in n):
            print(a['browser_download_url']); break
except Exception:
    pass
")
  if [[ -n "$ASSET_URL" ]]; then
    TMPDIR=$(mktemp -d)
    if curl -fsSL "$ASSET_URL" -o "$TMPDIR/scanner.tar.gz" 2>/dev/null; then
      tar -xzf "$TMPDIR/scanner.tar.gz" -C "$TMPDIR" 2>/dev/null || true
      SCANNER_BIN=$(find "$TMPDIR" -type f -iname "*realitlscanner*" -perm -u+x 2>/dev/null | head -1)
      [[ -z "$SCANNER_BIN" ]] && SCANNER_BIN=$(find "$TMPDIR" -type f -iname "*realitlscanner*" 2>/dev/null | head -1)
      [[ -n "$SCANNER_BIN" ]] && chmod +x "$SCANNER_BIN"
    fi
  fi
fi

if [[ -n "$SCANNER_BIN" ]]; then
  for candidate in "${SNI_CANDIDATES[@]}"; do
    log "Проверяю $candidate..."
    RESULT=$(timeout 10 "$SCANNER_BIN" -addr "$candidate" -timeout 5 2>&1 || true)
    if echo "$RESULT" | grep -q "feasible=true"; then
      SNI_DONOR="$candidate"
      log "Подтверждено: $candidate (TLS1.3 + H2, проверено с этого сервера)."
      break
    fi
  done
else
  warn "Не удалось получить RealiTLScanner — использую SNI-донора по умолчанию без верификации ($SNI_DONOR)."
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

cat > /tmp/remnawave_seed_profile.py <<'SEEDEOF'
#!/usr/bin/env python3
"""
Remnawave — seed a Config Profile with 3 shared Reality presets — by qellyka
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
PROFILE_NAME = os.environ.get("RW_PROFILE_NAME", "shared-reality-preset")
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
]

print("[1/2] Verifying API token...")
api("GET", "/api/hosts", API_TOKEN)
print("      OK.")

print("[2/2] Creating Config Profile with 3 shared Reality inbounds...")
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
print("Open remnawave-attach-and-hosts.sh next, on the node itself — it attaches")
print("this profile, and adds Hysteria2 (its own domain, mandatory) + an")
print("optional CDN inbound, both node-specific.")
print("=====================================================")
SEEDEOF

env \
  RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" RW_SNI_DONOR="$SNI_DONOR" \
  RW_TCP_PORT=443 RW_TCP_KEY="$TCP_KEY" RW_TCP_SID="$TCP_SID" \
  RW_GRPC_PORT=8443 RW_GRPC_KEY="$GRPC_KEY" RW_GRPC_SID="$GRPC_SID" RW_GRPC_SERVICE_NAME="$(openssl rand -hex 6)" \
  RW_XHTTP_PORT=2053 RW_XHTTP_KEY="$XHTTP_KEY" RW_XHTTP_SID="$XHTTP_SID" RW_XHTTP_PATH="/$(openssl rand -hex 8)/" \
  python3 /tmp/remnawave_seed_profile.py
