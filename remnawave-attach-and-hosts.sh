#!/usr/bin/env bash
# Attaches a shared Reality profile to a node, and creates Hysteria2 (its
# own domain — mandatory, that's how the protocol works) + optionally a
# CDN-fronted XHTTP inbound, both node-specific — by qellyka
#
# Runs ON the node itself (needs port 80 for ACME challenges, and installs
# a persistent Nginx). Because Hysteria2 and CDN each need their own
# domain/cert, this creates a NEW, node-specific Config Profile — copying
# the 3 shared Reality inbounds from the profile you pick as-is, adding
# Hysteria2 (always) and CDN-XHTTP (if you want it) on top. The shared
# profile itself is only read, never modified, so it stays reusable for
# other nodes.
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

DECOY_SITE_URL="https://raw.githubusercontent.com/qellyka/remnawave-installer/main/index.html"

read_panel_url() {
  local prompt="$1" __resultvar="$2" value
  read -rp "$prompt" value
  [[ "$value" =~ ^https?:// ]] || value="https://$value"
  printf -v "$__resultvar" '%s' "$value"
}

write_nginx_hardening() {
  mkdir -p /etc/nginx/snippets
  cat > /etc/nginx/snippets/ssl-params.conf <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
gzip on;
gzip_vary on;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
EOF
  # NOTE: as of the shared profile's current port layout, Reality+TCP no
  # longer uses 443 (moved to 9443 specifically so it wouldn't compete with
  # Nginx here) — the SNI-reject default_server is left disabled below
  # anyway for now. See the port-conflict note further down for the history.
}

issue_cert_for_domain() {
  local domain="$1"
  log "Проверяю DNS для $domain..."
  local resolved public_ip
  resolved=$(dig +short "$domain" A | tail -n1 || true)
  public_ip=$(curl -s -4 --max-time 5 https://api.ipify.org || true)
  if [[ -z "$resolved" ]]; then
    warn "$domain пока не резолвится. Certbot, скорее всего, не пройдёт, пока не создашь A-запись -> $public_ip"
  elif [[ "$resolved" != "$public_ip" ]]; then
    warn "$domain резолвится в $resolved, а не в IP этого сервера ($public_ip). Certbot может не пройти."
  fi

  if [[ ! -d "/etc/letsencrypt/live/$domain" ]]; then
    mkdir -p /var/www/certbot
    cat > "/etc/nginx/sites-available/$domain.bootstrap" <<EOF
server {
    listen 80;
    server_name $domain;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 404; }
}
EOF
    ln -sf "/etc/nginx/sites-available/$domain.bootstrap" "/etc/nginx/sites-enabled/$domain.bootstrap"
    nginx -t && systemctl reload nginx

    certbot certonly --webroot -w /var/www/certbot -d "$domain" --non-interactive --agree-tos \
      -m "admin@$domain" --no-eff-email || warn "Certbot не смог получить сертификат для $domain — поправь DNS и запусти certbot вручную позже"

    rm -f "/etc/nginx/sites-enabled/$domain.bootstrap" "/etc/nginx/sites-available/$domain.bootstrap"
  else
    log "Сертификат для $domain уже есть — пропускаю выпуск."
  fi
}

write_decoy_site() {
  mkdir -p /var/www/decoy-cdn
  if curl -fsSL "$DECOY_SITE_URL" -o /var/www/decoy-cdn/index.html 2>/dev/null && [[ -s /var/www/decoy-cdn/index.html ]]; then
    log "Заглушка-камуфляж скачана с GitHub."
  else
    warn "Не удалось скачать заглушку с GitHub ($DECOY_SITE_URL) — использую минимальный запасной вариант."
    cat > /var/www/decoy-cdn/index.html <<'DECOYEOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>Service</title></head>
<body>Hello</body></html>
DECOYEOF
  fi
}

suggest_domain() {
  # $1 = base address, $2 = subdomain label -> echoes a suggested FQDN, or
  # empty if the base address doesn't look like a domain (e.g. a raw IP).
  local base="$1" label="$2"
  if [[ "$base" == *.* && ! "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$label.$base"
  fi
}

echo "==================================================="
echo "  Remnawave — attach profile, Hysteria2 + optional CDN — by qellyka"
echo "==================================================="
echo "Этот скрипт ставит Nginx и получает сертификаты — выполняй его прямо"
echo "на самой ноде (нужен доступ к порту 80)."
echo ""
read_panel_url "URL панели (panel.example.com или https://panel.example.com): " PANEL_URL
read -rp "API-токен: " API_TOKEN
[[ -n "$API_TOKEN" ]] || die "Токен обязателен"

wait_for_apt_lock
apt-get update -qq || true
wait_for_apt_lock
apt-get install -y -qq curl python3 openssl dnsutils nginx certbot \
  || die "apt-get install не смог поставить один из пакетов (curl python3 openssl dnsutils nginx certbot) — прочитай вывод apt выше для точной причины"

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
echo "Доступные профили (общие, с 3 Reality-инбаундами):"
echo "$PROFILES_LIST" | awk -F'|' '{printf "  %s) %s\n", $2, $4}'
echo ""
read -rp "Выбери номер профиля: " PROFILE_PICK
PICKED_PROFILE=$(echo "$PROFILES_LIST" | awk -F'|' -v n="$PROFILE_PICK" '$1=="P" && $2==n')
[[ -n "$PICKED_PROFILE" ]] || die "Некорректный выбор"
PROFILE_UUID=$(echo "$PICKED_PROFILE" | cut -d'|' -f3)
PROFILE_NAME=$(echo "$PICKED_PROFILE" | cut -d'|' -f4)
log "Выбран профиль: $PROFILE_NAME ($PROFILE_UUID)"

echo ""
echo "Публичный адрес этой ноды — то, к чему подключаются клиенты для трёх"
echo "общих Reality-инбаундов (не обязательно совпадает с адресом, который"
echo "панель использует для управления нодой)."
read -rp "Публичный адрес ноды: " NODE_PUBLIC_ADDRESS
[[ -n "$NODE_PUBLIC_ADDRESS" ]] || die "Адрес обязателен"

# --- Hysteria2: всегда свой домен, без вопросов ---
echo ""
echo "Hysteria2 всегда получает собственный домен и настоящий сертификат"
echo "Let's Encrypt — так устроен сам протокол, это не выбор."
HY2_SUGGESTED=$(suggest_domain "$NODE_PUBLIC_ADDRESS" "hy2")
if [[ -n "$HY2_SUGGESTED" ]]; then
  read -rp "Домен для Hysteria2 [$HY2_SUGGESTED]: " HY2_DOMAIN
  HY2_DOMAIN="${HY2_DOMAIN:-$HY2_SUGGESTED}"
else
  read -rp "Домен для Hysteria2 (например hy2.node-pl.example.com): " HY2_DOMAIN
fi
[[ -n "$HY2_DOMAIN" ]] || die "Домен обязателен для Hysteria2"

PUBLIC_IP=$(curl -s -4 --max-time 5 https://api.ipify.org || echo "?")
echo ""
echo "Нужна A-запись:  $HY2_DOMAIN  ->  $PUBLIC_IP"
echo "Если ещё не создал — сделай сейчас у регистратора (может занять пару минут)."
read -rp "Нажми Enter, когда готов продолжать: "

write_nginx_hardening
issue_cert_for_domain "$HY2_DOMAIN"

# NOTE: no Nginx site is written here for $HY2_DOMAIN on 443 (Hysteria2's
# own inbound already has a built-in masquerade — proxies to bing.com for
# anything that isn't real Hysteria2/QUIC traffic — so a local decoy site on
# the domain adds little). This used to be load-bearing (the shared
# profile's Reality+TCP inbound needed sole ownership of 443, and Nginx here
# broke it outright), but Reality+TCP has since moved off 443 (now 9443),
# so that conflict no longer applies — this is just left as-is for
# simplicity, not because it's still required. Restorable if wanted.

HY2_CERT_PEM=""
HY2_KEY_PEM=""
if [[ -d "/etc/letsencrypt/live/$HY2_DOMAIN" ]]; then
  HY2_CERT_PEM=$(cat "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem")
  HY2_KEY_PEM=$(cat "/etc/letsencrypt/live/$HY2_DOMAIN/privkey.pem")
else
  die "Сертификат для $HY2_DOMAIN не получен — без него Hysteria2 работать не будет. Поправь DNS и запусти скрипт заново."
fi

# --- CDN: опционально ---
echo ""
echo "Также настроить CDN-инбаунд (TLS+XHTTP через CDN-провайдера, обход"
echo "белых списков мобильных операторов)? Нужны два разных домена: origin"
echo "(для этой ноды и сертификата) и публичный CDN-домен (то, что реально"
echo "видят клиенты через сам CDN-сервис — этот CDN-ресурс тебе нужно будет"
echo "создать вручную в консоли провайдера, скрипт этого не делает)."
echo "  1) Да"
echo "  2) Нет"
read -rp "Введите номер [1-2]: " ENABLE_CDN_CHOICE
ENABLE_CDN=false
CDN_ORIGIN_DOMAIN=""
CDN_PUBLIC_DOMAIN=""
CDN_XHTTP_PATH=""
if [[ "$ENABLE_CDN_CHOICE" == "1" ]]; then
  ENABLE_CDN=true
  CDN_SUGGESTED=$(suggest_domain "$NODE_PUBLIC_ADDRESS" "cdn-origin")
  if [[ -n "$CDN_SUGGESTED" ]]; then
    read -rp "Origin-домен для CDN [$CDN_SUGGESTED]: " CDN_ORIGIN_DOMAIN
    CDN_ORIGIN_DOMAIN="${CDN_ORIGIN_DOMAIN:-$CDN_SUGGESTED}"
  else
    read -rp "Origin-домен для CDN: " CDN_ORIGIN_DOMAIN
  fi
  [[ -n "$CDN_ORIGIN_DOMAIN" ]] || die "Origin-домен обязателен для CDN"
  read -rp "Публичный домен CDN-ресурса (например cdn.example.com): " CDN_PUBLIC_DOMAIN
  [[ -n "$CDN_PUBLIC_DOMAIN" ]] || die "Публичный CDN-домен обязателен"

  PUBLIC_IP=$(curl -s -4 --max-time 5 https://api.ipify.org || echo "?")
  echo ""
  echo "Нужна A-запись для origin:  $CDN_ORIGIN_DOMAIN  ->  $PUBLIC_IP"
  echo "Публичный CDN-домен ($CDN_PUBLIC_DOMAIN) настраивается отдельно, в"
  echo "консоли CDN-провайдера — про это скрипт напомнит в конце."
  read -rp "Нажми Enter, когда A-запись для origin готова: "

  issue_cert_for_domain "$CDN_ORIGIN_DOMAIN"
  CDN_XHTTP_PATH="/$(openssl rand -hex 8)/"
  CDN_XHTTP_LOCAL_PORT=20000

  if [[ -d "/etc/letsencrypt/live/$CDN_ORIGIN_DOMAIN" ]]; then
    cat > /etc/nginx/sites-available/remnanode-cdn <<EOF
upstream xray_xhttp { server 127.0.0.1:$CDN_XHTTP_LOCAL_PORT; keepalive 128; }
server {
    listen 80; server_name $CDN_ORIGIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2; server_name $CDN_ORIGIN_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$CDN_ORIGIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CDN_ORIGIN_DOMAIN/privkey.pem;
    include /etc/nginx/snippets/ssl-params.conf;

    location = /health {
        default_type application/json;
        return 200 '{"status":"ok"}';
    }

    location $CDN_XHTTP_PATH {
        proxy_pass http://xray_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_max_temp_file_size 0;
        proxy_socket_keepalive on;
        client_max_body_size 0;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        add_header X-Accel-Buffering no always;
        add_header Cache-Control "no-store, no-cache" always;
        add_header Accept-Ranges none always;
    }

    location / {
        root /var/www/decoy-cdn;
        index index.html;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/remnanode-cdn /etc/nginx/sites-enabled/
  else
    warn "Сертификат для $CDN_ORIGIN_DOMAIN не получен — CDN-инбаунд отключаю."
    ENABLE_CDN=false
  fi
fi

nginx -t && systemctl reload nginx

echo ""
echo "Префикс к названию хостов — необязательно, добавится перед именем каждого"
echo "хоста через пробел (например флаг страны: 🇵🇱 даст «🇵🇱 Reality TCP»)."
read -rp "Префикс (Enter — пропустить): " HOST_PREFIX

cat > /tmp/remnawave_attach_and_hosts.py <<'MAINEOF'
#!/usr/bin/env python3
"""
Remnawave — attach shared profile to node, add node-specific Hysteria2 (+
optional CDN), create hosts — by qellyka
Reads the shared profile's stored raw config back via the API to copy the
3 Reality inbounds as-is (rather than re-typing values a separate script
run already randomized), then builds a NEW, node-specific profile with
those 3 plus Hysteria2 (and CDN, if enabled). The shared profile is only
read, never modified.
"""
import json
import os
import sys
import urllib.request
import urllib.error
import subprocess


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
SOURCE_PROFILE_UUID = os.environ["RW_PROFILE_UUID"]
SOURCE_PROFILE_NAME = os.environ["RW_PROFILE_NAME"]
NODE_ADDRESS = os.environ["RW_NODE_PUBLIC_ADDRESS"]
HOST_PREFIX = os.environ.get("RW_HOST_PREFIX", "").strip()
HY2_DOMAIN = os.environ["RW_HY2_DOMAIN"]
HY2_CERT_PEM = os.environ["RW_HY2_CERT_PEM"]
HY2_KEY_PEM = os.environ["RW_HY2_KEY_PEM"]
ENABLE_CDN = os.environ.get("RW_ENABLE_CDN", "false") == "true"
CDN_ORIGIN_DOMAIN = os.environ.get("RW_CDN_ORIGIN_DOMAIN", "")
CDN_PUBLIC_DOMAIN = os.environ.get("RW_CDN_PUBLIC_DOMAIN", "")
CDN_XHTTP_PATH = os.environ.get("RW_CDN_XHTTP_PATH", "")
CDN_XHTTP_LOCAL_PORT = int(os.environ.get("RW_CDN_XHTTP_LOCAL_PORT", "20000"))


def remark(name):
    return f"{HOST_PREFIX} {name}" if HOST_PREFIX else name


print("[1/5] Verifying API token...")
api("GET", "/api/hosts", API_TOKEN)
print("      OK.")

print("[2/5] Reading shared profile's stored config...")
source_resp = api("GET", f"/api/config-profiles/{SOURCE_PROFILE_UUID}", API_TOKEN)["response"]
source_raw_config = source_resp["config"]
source_raw_by_tag = {ib["tag"]: ib for ib in source_raw_config.get("inbounds", [])}

WANTED_SHARED_TAGS = ["reality-tcp", "reality-grpc", "reality-xhttp"]
missing = [t for t in WANTED_SHARED_TAGS if t not in source_raw_by_tag]
if missing:
    die(f"This profile is missing expected inbound(s): {missing}. "
        f"Found: {list(source_raw_by_tag.keys())}")

print("[3/5] Building node-specific profile (shared Reality x3 + Hysteria2"
      + (" + CDN)..." if ENABLE_CDN else ")..."))

# Xray inbound tags must be globally unique across the whole panel database
# (confirmed via a real HTTP 409 — "Inbounds with same tag already exists in
# database" — not just unique within one profile). Since we're copying
# inbounds FROM the shared profile (which already owns "reality-tcp" etc.)
# INTO a brand-new profile, reusing those exact tag strings collides
# immediately — and would also collide between different nodes' own
# profiles later. Suffix every tag here with something derived from this
# node's own address, so it can't collide with anything.
import copy as _copy
import re as _re
_tag_suffix = _re.sub(r"[^A-Za-z0-9_-]", "-", NODE_ADDRESS)[:20].strip("-")


def _retagged(inbound, new_tag):
    ib = _copy.deepcopy(inbound)
    ib["tag"] = new_tag
    return ib


TCP_TAG = f"reality-tcp-{_tag_suffix}"
GRPC_TAG = f"reality-grpc-{_tag_suffix}"
XHTTP_TAG = f"reality-xhttp-{_tag_suffix}"
HY2_TAG = f"hysteria2-{_tag_suffix}"
CDN_TAG = f"cdn-xhttp-{_tag_suffix}"

hysteria2_inbound = {
    "tag": HY2_TAG,
    "listen": "0.0.0.0",
    "port": 8444,
    "protocol": "hysteria",
    "settings": {"version": 2, "clients": []},
    "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
    "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
            "alpn": ["h3"], "minVersion": "1.3", "maxVersion": "1.3",
            "serverName": HY2_DOMAIN,
            "certificates": [{
                "certificate": HY2_CERT_PEM.splitlines(),
                "key": HY2_KEY_PEM.splitlines()
            }]
        },
        "hysteriaSettings": {
            "version": 2, "udpIdleTimeout": 60,
            "masquerade": {"type": "proxy", "url": "https://www.bing.com", "rewriteHost": True}
        },
        # Hysteria defaults to "brutal" congestion control unless this is set
        # explicitly — brutal needs two-way client/server negotiation that not
        # every client implements, which can fail the QUIC handshake silently.
        "finalmask": {"quicParams": {"congestion": "bbr"}}
    }
}

new_inbounds = [
    _retagged(source_raw_by_tag["reality-tcp"], TCP_TAG),
    _retagged(source_raw_by_tag["reality-grpc"], GRPC_TAG),
    _retagged(source_raw_by_tag["reality-xhttp"], XHTTP_TAG),
    hysteria2_inbound,
]

if ENABLE_CDN:
    new_inbounds.append({
        "tag": CDN_TAG,
        "listen": "127.0.0.1",
        "port": CDN_XHTTP_LOCAL_PORT,
        "protocol": "vless",
        "settings": {"clients": [], "decryption": "none"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        "streamSettings": {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
                "path": CDN_XHTTP_PATH,
                "mode": "packet-up",
                "xPaddingBytes": "100-1000",
                "xPaddingObfsMode": True,
                "xPaddingKey": "hash",
                "xPaddingHeader": "X-Client-Version",
                "xPaddingPlacement": "queryInHeader",
                "xPaddingMethod": "tokenish",
                "uplinkHTTPMethod": "GET",
                "uplinkDataPlacement": "body",
                "scMaxEachPostBytes": "500000-1000000",
                "scMinPostsIntervalMs": "50-150",
                "scStreamUpServerSecs": "60-180",
                "uplinkChunkSize": 131072,
                "enableXmux": True,
                "xmux": {
                    "maxConcurrency": "16-32", "maxConnections": 0,
                    "cMaxReuseTimes": 1000, "hMaxRequestTimes": "600-900",
                    "hMaxReusableSecs": "100", "hKeepAlivePeriod": 20000
                }
            }
        }
    })

# Config Profile names: max 30 chars, only letters/digits/underscore/dash/space
# (confirmed from the API's own validation error — no dots, which domains
# always have, so this can't just be "{name}-{address}" as originally written).
_short_node = _re.sub(r"[^A-Za-z0-9_\s-]", "-", NODE_ADDRESS)
PROFILE_DISPLAY_NAME = f"node-{_short_node}"[:30].rstrip("-")

new_profile_body = {
    "name": PROFILE_DISPLAY_NAME,
    "config": {
        "inbounds": new_inbounds,
        "outbounds": source_raw_config.get("outbounds", [{"protocol": "freedom", "tag": "direct"}])
    }
}
new_profile_resp = api("POST", "/api/config-profiles", API_TOKEN, new_profile_body)["response"]
PROFILE_UUID = new_profile_resp["uuid"]
tag_to_uuid = {ib["tag"]: ib["uuid"] for ib in new_profile_resp["inbounds"]}
raw_by_tag = {ib["tag"]: ib for ib in new_inbounds}
print(f"      New profile: {PROFILE_UUID}")

print("[4/5] Attaching node to this profile...")
active_tags = [TCP_TAG, GRPC_TAG, XHTTP_TAG, HY2_TAG] + ([CDN_TAG] if ENABLE_CDN else [])
node_body = {
    "uuid": NODE_UUID,
    "configProfile": {
        "activeConfigProfileUuid": PROFILE_UUID,
        "activeInbounds": [tag_to_uuid[t] for t in active_tags]
    }
}
api("PATCH", "/api/nodes", API_TOKEN, node_body)
print("      Done.")

print("[5/5] Creating hosts...")
created = {}

# --- Reality + TCP ---
tcp_raw = raw_by_tag[TCP_TAG]
tcp_sni = tcp_raw["streamSettings"]["realitySettings"]["serverNames"][0]
host = api("POST", "/api/hosts", API_TOKEN, {
    "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid[TCP_TAG]},
    "remark": remark("Reality TCP"),
    "address": NODE_ADDRESS,
    "port": tcp_raw["port"],
    "sni": tcp_sni,
    "fingerprint": "chrome",
    "securityLayer": "DEFAULT"
})["response"]
created["reality-tcp"] = {"port": tcp_raw["port"], "sni": tcp_sni, "host_uuid": host["uuid"]}
print(f"      reality-tcp   -> Host {host['uuid']}")

# --- Reality + gRPC ---
grpc_raw = raw_by_tag[GRPC_TAG]
grpc_sni = grpc_raw["streamSettings"]["realitySettings"]["serverNames"][0]
grpc_service = grpc_raw["streamSettings"]["grpcSettings"]["serviceName"]
host = api("POST", "/api/hosts", API_TOKEN, {
    "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid[GRPC_TAG]},
    "remark": remark("Reality gRPC"),
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
xhttp_raw = raw_by_tag[XHTTP_TAG]
xhttp_sni = xhttp_raw["streamSettings"]["realitySettings"]["serverNames"][0]
xhttp_path = xhttp_raw["streamSettings"]["xhttpSettings"]["path"]
host = api("POST", "/api/hosts", API_TOKEN, {
    "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid[XHTTP_TAG]},
    "remark": remark("Reality XHTTP"),
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
host = api("POST", "/api/hosts", API_TOKEN, {
    "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid[HY2_TAG]},
    "remark": remark("Hysteria2"),
    "address": HY2_DOMAIN,
    "port": 8444,
    "sni": HY2_DOMAIN,
    "securityLayer": "DEFAULT"
})["response"]
created["hysteria2"] = {"domain": HY2_DOMAIN, "port": 8444, "host_uuid": host["uuid"]}
print(f"      hysteria2     -> Host {host['uuid']}")

# --- CDN (optional) ---
if ENABLE_CDN:
    host = api("POST", "/api/hosts", API_TOKEN, {
        "inbound": {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_to_uuid[CDN_TAG]},
        "remark": remark(f"CDN — {CDN_PUBLIC_DOMAIN}"),
        "address": CDN_PUBLIC_DOMAIN,
        "port": 443,
        "path": CDN_XHTTP_PATH,
        "sni": CDN_PUBLIC_DOMAIN,
        "alpn": "h2,http/1.1",
        "fingerprint": "chrome",
        "securityLayer": "NONE",
        "xhttpExtraParams": {
            "uplinkDataPlacement": "body",
            "uplinkChunkSize": 131072,
            "scMaxEachPostBytes": "500000-1000000",
            "scMinPostsIntervalMs": "50-150",
            "scStreamUpServerSecs": "60-180",
            "xPaddingBytes": "100-1000",
            "xPaddingObfsMode": True,
            "xPaddingKey": "hash"
        }
    })["response"]
    created["cdn-xhttp"] = {"public_domain": CDN_PUBLIC_DOMAIN, "origin_domain": CDN_ORIGIN_DOMAIN, "host_uuid": host["uuid"]}
    print(f"      cdn-xhttp     -> Host {host['uuid']}")

print()
print("=====================================================")
print("Done. Node attached, hosts created:")
for tag, info in created.items():
    print(f"  {tag}: {json.dumps(info)}")
print()
print(f"Hysteria2 uses a real Let's Encrypt cert for {HY2_DOMAIN} — trusted by")
print("clients automatically, no allowInsecure or pinning needed.")
if ENABLE_CDN:
    print()
    print(f"CDN: create the actual CDN resource in your provider's console now,")
    print(f"  origin: https://{CDN_ORIGIN_DOMAIN} (origin protocol: HTTPS)")
    print(f"  public domain: {CDN_PUBLIC_DOMAIN}")
    print("The script can't do this part — it's a manual step in the CDN's own UI.")
print("PLEASE open the panel UI and visually confirm everything looks correct.")
print("=====================================================")
MAINEOF

RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" RW_NODE_UUID="$NODE_UUID" \
  RW_PROFILE_UUID="$PROFILE_UUID" RW_PROFILE_NAME="$PROFILE_NAME" \
  RW_NODE_PUBLIC_ADDRESS="$NODE_PUBLIC_ADDRESS" RW_HOST_PREFIX="$HOST_PREFIX" \
  RW_HY2_DOMAIN="$HY2_DOMAIN" RW_HY2_CERT_PEM="$HY2_CERT_PEM" RW_HY2_KEY_PEM="$HY2_KEY_PEM" \
  RW_ENABLE_CDN="$ENABLE_CDN" RW_CDN_ORIGIN_DOMAIN="${CDN_ORIGIN_DOMAIN:-}" \
  RW_CDN_PUBLIC_DOMAIN="${CDN_PUBLIC_DOMAIN:-}" RW_CDN_XHTTP_PATH="${CDN_XHTTP_PATH:-}" \
  RW_CDN_XHTTP_LOCAL_PORT="${CDN_XHTTP_LOCAL_PORT:-20000}" \
  python3 /tmp/remnawave_attach_and_hosts.py
