#!/usr/bin/env bash
# Remnawave — установка ноды с НУЛЯ на чистом сервере: Docker, сама нода,
# 6 инбаундов (вкл. BRIDGE_IN), хосты, Nginx с сайтом-заглушкой — by qellyka
#
# Заходишь на чистый Ubuntu/Debian, запускаешь — скрипт делает ВСЁ сам:
#   - ставит Docker + Compose, если их нет;
#   - логинится в панель (логин/пароль админа) и сам выпускает API-токен;
#   - выпускает сертификат, ставит Nginx + заглушку;
#   - создаёт в панели профиль с 6 инбаундами и САМУ НОДУ (через API),
#     забирает у панели SECRET_KEY;
#   - разворачивает контейнер remnanode с этим ключом и свежим Xray;
#   - создаёт хосты, добавляет инбаунды в сквады;
#   - открывает порты (NODE_PORT — только для IP панели);
#   - ставит хук продления сертификата.
#
# Авторизация в v3 (важно и подтверждено спекой панели):
#   Панель на /api/* НЕ принимает админский JWT напрямую (403 "must create
#   own API-token"). Единственный рабочий путь: логин -> выпустить API-токен
#   (`POST /api/api-tokens` разрешён ТОЛЬКО админским JWT) -> дальше всё
#   делать токеном. Пароль спрашивается один раз, на диск не пишется.
#   На диск (chmod 600) кладётся только выпущенный API-токен.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }
hr()   { echo "---------------------------------------------------"; }

[[ $EUID -eq 0 ]] || die "Запускай от root (sudo)."

DECOY_SITE_URL="https://raw.githubusercontent.com/qellyka/remnawave-installer/main/index.html"
XRAY_INSTALLER_URL="https://raw.githubusercontent.com/remnawave/scripts/main/scripts/install-latest-xray.sh"
NODE_DIR="/opt/remnanode"
XRAY_CUSTOM="$NODE_DIR/xray-custom"
SSL_DIR="/etc/nginx/ssl"
NODE_IMAGE="ghcr.io/remnawave/node:latest"

# Порты инбаундов — покупная схема + два прямых Reality + мост.
PORT_REALITY_TCP=9443
PORT_REALITY_GRPC=2083
PORT_REALITY_XHTTP=2053
PORT_HY2=8443          # UDP; TCP 8443 занимает nginx-камуфляж
PORT_CDN_LOCAL=4443    # xray слушает localhost, наружу через nginx
PORT_BRIDGE=8888       # BRIDGE_IN, server-side routing (между нодами)
NODE_PORT=2222         # внутренний API ноды <-> панель

wait_for_apt_lock() {
  local waited=0 max_wait=300
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [[ $waited -eq 0 ]] && warn "apt/dpkg занят (обычно сразу после установки сервера). Жду..."
    sleep 5; waited=$((waited + 5))
    [[ $waited -ge $max_wait ]] && die "apt/dpkg занят больше 5 минут — проверь: ps aux | grep -i apt"
  done
  [[ $waited -gt 0 ]] && log "Дождался освобождения apt/dpkg (${waited}s)."
  return 0
}

read_clean() {  # $1 prompt, $2 varname, $3 charset — чистит артефакты вставки
  local prompt="$1" __var="$2" charset="$3" value
  read -rp "$prompt" value
  value="$(echo "$value" | tr -cd "$charset")"
  printf -v "$__var" '%s' "$value"
}

echo "==================================================="
echo "  Remnawave — установка ноды с НУЛЯ (6 инбаундов)"
echo "  by qellyka"
echo "==================================================="
echo "Чистый сервер -> готовая нода. Нужна только A-запись на домен ноды."
echo ""

# ---------------------------------------------------------------------------
# Сбор входных данных (до долгих операций — чтобы не бросать на полпути)
# ---------------------------------------------------------------------------
read_clean "URL панели (panel.example.com или https://panel.example.com): " PANEL_URL 'A-Za-z0-9.:/-'
[[ "$PANEL_URL" =~ ^https?:// ]] || PANEL_URL="https://$PANEL_URL"
PANEL_URL="${PANEL_URL%/}"

echo ""
echo "Авторизация в панели:"
echo "  1) Готовый API-токен — СОЗДАЙ его в UI: Settings -> API Tokens (рекомендуется)"
echo "  2) Логин + пароль (скрипт попробует выпустить токен сам — многие панели"
echo "     это ЗАПРЕЩАЮТ и вернут 403 'must create own API-token')"
read -rp "Введите номер [1-2]: " AUTH_CHOICE
API_TOKEN=""; RW_LOGIN=""; RW_PASSWORD=""
if [[ "$AUTH_CHOICE" == "2" ]]; then
  read -rp "Логин администратора панели: " RW_LOGIN
  read -rsp "Пароль администратора: " RW_PASSWORD; echo
  [[ -n "$RW_LOGIN" && -n "$RW_PASSWORD" ]] || die "Логин и пароль обязательны"
else
  read -rp "API-токен: " API_TOKEN
  API_TOKEN="$(echo "$API_TOKEN" | tr -d '[:space:]')"
  [[ -n "$API_TOKEN" ]] || die "Токен пуст"
fi

read_clean "Имя ноды в панели (например DE-1): " NODE_NAME 'A-Za-z0-9 _.-'
[[ -n "$NODE_NAME" ]] || NODE_NAME="node-$(date +%s)"

hr
echo "Домен этой ноды — на него сертификат, заглушка, origin CDN, SNI Hy2."
read_clean "Домен ноды (например de1.example.com): " NODE_DOMAIN 'A-Za-z0-9.-'
[[ -n "$NODE_DOMAIN" ]] || die "Домен обязателен"

hr
echo "Публичный домен CDN (Yandex CDN) — Enter, чтобы пропустить (тогда 5 инбаундов)."
read_clean "Публичный домен CDN (например cdn.example.com): " CDN_PUBLIC_DOMAIN 'A-Za-z0-9.-'
ENABLE_CDN=false; [[ -n "$CDN_PUBLIC_DOMAIN" ]] && ENABLE_CDN=true

hr
echo "BRIDGE_IN — служебный инбаунд для маршрутизации трафика МЕЖДУ нодами"
echo "(эта нода станет промежуточной/входной; трафик придёт с другой ноды)."
echo "В подписку он не идёт. Наружу открывать 8888 небезопасно, если не"
echo "ограничить его IP нод-источников — их спрошу ниже."
read -rp "Добавить BRIDGE_IN? [y/N]: " BRIDGE_ANS
ENABLE_BRIDGE=false
BRIDGE_PEERS=""
if [[ "$BRIDGE_ANS" =~ ^[Yy]$ ]]; then
  ENABLE_BRIDGE=true
  echo "IP нод-источников, которым разрешить порт $PORT_BRIDGE (через пробел)."
  echo "Enter — открыть всем (НЕ рекомендуется; для теста)."
  read -rp "IP источников: " BRIDGE_PEERS
fi

hr
echo "Префикс к именам хостов — необязательно (например флаг страны)."
read -rp "Префикс (Enter — пропустить): " HOST_PREFIX

# IP панели (для правила файрвола на NODE_PORT) — резолвим хост панели.
PANEL_HOST="$(echo "$PANEL_URL" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##')"
PANEL_IP=""

hr
echo "Проверь перед стартом:"
echo "  A-запись $NODE_DOMAIN -> IP этого сервера"
[[ "$ENABLE_CDN" == "true" ]] && echo "  $CDN_PUBLIC_DOMAIN — CNAME на Yandex CDN добавим ПОСЛЕ (инструкция в конце)"
read -rp "Enter, когда A-запись для $NODE_DOMAIN готова: "

# ---------------------------------------------------------------------------
# Зависимости + Docker
# ---------------------------------------------------------------------------
log "Ставлю зависимости..."
wait_for_apt_lock
apt-get update -qq || true
wait_for_apt_lock
apt-get install -y -qq curl python3 openssl dnsutils nginx certbot ca-certificates unzip tar \
  || die "apt-get не смог поставить зависимости — смотри вывод выше"

if ! command -v docker >/dev/null 2>&1; then
  log "Docker не найден — ставлю официальным скриптом get.docker.com..."
  curl -fsSL https://get.docker.com | sh || die "Не удалось поставить Docker"
  systemctl enable --now docker >/dev/null 2>&1 || true
else
  log "Docker уже установлен."
fi
# Compose v2 (плагин). Если нет — ставим.
if ! docker compose version >/dev/null 2>&1; then
  warn "docker compose (v2) не найден — ставлю плагин..."
  wait_for_apt_lock
  apt-get install -y -qq docker-compose-plugin 2>/dev/null || \
    warn "Не смог поставить docker-compose-plugin — если compose нет, поставь вручную."
fi

PUBLIC_IP=$(curl -s -4 --max-time 5 https://api.ipify.org || echo "")
RESOLVED=$(dig +short "$NODE_DOMAIN" A | tail -n1 || true)
if [[ -z "$RESOLVED" ]]; then
  warn "$NODE_DOMAIN пока не резолвится — certbot, скорее всего, не пройдёт."
elif [[ -n "$PUBLIC_IP" && "$RESOLVED" != "$PUBLIC_IP" ]]; then
  warn "$NODE_DOMAIN резолвится в $RESOLVED, а не в $PUBLIC_IP — certbot может не пройти."
else
  log "DNS в порядке: $NODE_DOMAIN -> $RESOLVED"
fi
PANEL_IP=$(dig +short "$PANEL_HOST" A | tail -n1 || true)
[[ -n "$PANEL_IP" ]] && log "IP панели ($PANEL_HOST): $PANEL_IP — открою NODE_PORT только ему."

# ---------------------------------------------------------------------------
# Авторизация
# ---------------------------------------------------------------------------
if [[ "$AUTH_CHOICE" == "2" ]]; then
  cat > /tmp/rw_mint_token.py <<'MINTEOF'
import json, os, sys, urllib.request, urllib.error
PANEL = os.environ["RW_PANEL_URL"].rstrip("/")

def call(path, method="GET", body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PANEL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token: req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode()), None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}"
    except Exception as e:
        return None, str(e)

r, err = call("/api/auth/login", "POST",
              {"username": os.environ["RW_LOGIN"], "password": os.environ["RW_PASSWORD"]})
if err:
    print(f"[ERROR] Логин не прошёл: {err}", file=sys.stderr); sys.exit(1)
resp = r.get("response") if isinstance(r, dict) else None
jwt = resp.get("accessToken") if isinstance(resp, dict) else None
if not jwt:
    print(f"[ERROR] Панель не вернула accessToken (2FA? неверный пароль?): {json.dumps(r)[:200]}",
          file=sys.stderr); sys.exit(1)

# Тело зависит от версии панели. Актуальная (docs.rw): {name, expiresInDays,
# scopes}. scopes:["*"] = полный доступ (без него токен может быть бесправным).
# Старые версии: {tokenName}. Пробуем по очереди, выходим на первом успехе.
tname = "node-deploy-" + os.urandom(2).hex()
bodies = [
    {"name": tname, "expiresInDays": 3650, "scopes": ["*"]},
    {"name": tname, "expiresInDays": 3650},
    {"tokenName": "node-deploy"},
]
errors = []
for path in ("/api/tokens", "/api/api-tokens"):
    for body in bodies:
        resp2, err = call(path, "POST", body, token=jwt)
        if err:
            errors.append(f"{path} [{','.join(body)}] -> {err}")
            continue
        node = resp2.get("response") or resp2
        tok = node.get("token") or node.get("apiToken") or node.get("accessToken")
        if tok:
            print(tok); sys.exit(0)
        errors.append(f"{path} -> ответ без поля token: {json.dumps(resp2)[:200]}")
print("[ERROR] Панель не дала выпустить токен из логина:", file=sys.stderr)
for e in errors:
    print("  " + e, file=sys.stderr)
print("Если везде 403 'must create own API-token' — эта панель блокирует "
      "программный выпуск. Создай токен вручную: Settings -> API Tokens -> Create "
      "(scope '*'), и перезапусти с вариантом 1 (готовый токен).", file=sys.stderr)
sys.exit(2)
MINTEOF
  log "Логинюсь и выпускаю API-токен..."
  API_TOKEN=$(RW_PANEL_URL="$PANEL_URL" RW_LOGIN="$RW_LOGIN" RW_PASSWORD="$RW_PASSWORD" \
    python3 /tmp/rw_mint_token.py) \
    || die "Не удалось выпустить токен. Создай его в UI (Settings -> API Tokens) и запусти заново с вариантом 1."
  unset RW_PASSWORD
  rm -f /tmp/rw_mint_token.py
  log "API-токен получен."
fi

# Проверяем токен (обе ветки): реальный вызов к /api/*.
cat > /tmp/rw_check_token.py <<'CHKEOF'
import json, os, sys, urllib.request, urllib.error
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
req = urllib.request.Request(PANEL + "/api/hosts", method="GET")
req.add_header("Authorization", "Bearer " + TOK)
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        r.read(); print("OK")
except urllib.error.HTTPError as e:
    body = e.read().decode(errors='replace')[:300]
    print(f"[ERROR] Токен не принят: HTTP {e.code}: {body}", file=sys.stderr)
    if e.code == 403 and "must create own API-token" in body:
        print("Это не API-токен (похоже на админскую сессию). Создай именно API Token "
              "в UI: Settings -> API Tokens -> Create, и вставь его.", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"[ERROR] {e}", file=sys.stderr); sys.exit(1)
CHKEOF
log "Проверяю токен..."
RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" python3 /tmp/rw_check_token.py \
  || die "Токен не работает (см. выше)."
rm -f /tmp/rw_check_token.py
log "Токен рабочий."

# Сохраним токен для повторных прогонов (chmod 600).
umask 077; echo "$API_TOKEN" > "$NODE_DIR.token" 2>/dev/null || echo "$API_TOKEN" > /root/.rw_node_token
umask 022

# ---------------------------------------------------------------------------
# Выбор Internal Squad'ов (в какие добавить инбаунды ноды)
# ---------------------------------------------------------------------------
cat > /tmp/rw_list_squads.py <<'SQEOF'
import json, os, sys, urllib.request, urllib.error
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
req = urllib.request.Request(PANEL + "/api/internal-squads", method="GET")
req.add_header("Authorization", "Bearer " + TOK)
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.loads(r.read().decode())
except Exception as e:
    print(f"[ERROR] {e}", file=sys.stderr); sys.exit(1)
b = data.get("response", data)
squads = b.get("internalSquads") if isinstance(b, dict) else b
if isinstance(b, dict) and squads is None: squads = b.get("data", [])
for s in (squads or []):
    n = len(s.get("inbounds") or [])
    print(f"{s['uuid']}|{s.get('name','?')}|{n}")
SQEOF

SQUAD_MODE="ALL"; SQUAD_UUIDS=""; NEW_SQUAD_NAME=""
SQUADS_LIST=$(RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" python3 /tmp/rw_list_squads.py 2>/dev/null || true)
rm -f /tmp/rw_list_squads.py
hr
echo "Internal Squads — в какие добавить инбаунды этой ноды?"
if [[ -n "$SQUADS_LIST" ]]; then
  echo "Существующие сквады:"
  i=1
  declare -a SQ_UUID_ARR=()
  while IFS='|' read -r uuid name cnt; do
    [[ -z "$uuid" ]] && continue
    printf "  %s) %s  (инбаундов: %s)\n" "$i" "$name" "$cnt"
    SQ_UUID_ARR[$i]="$uuid"
    i=$((i+1))
  done <<< "$SQUADS_LIST"
else
  echo "(существующих сквадов нет или список не получен)"
fi
echo ""
echo "  a) во ВСЕ существующие сквады"
echo "  n) создать НОВЫЙ сквад"
echo "  s) пропустить (никуда не добавлять)"
echo "  или введи номера через пробел (например: 1 3)"
read -rp "Выбор [a/n/s/номера]: " SQ_CHOICE
case "$SQ_CHOICE" in
  a|A|"") SQUAD_MODE="ALL" ;;
  s|S) SQUAD_MODE="NONE" ;;
  n|N)
    SQUAD_MODE="NEW"
    read -rp "Имя нового сквада: " NEW_SQUAD_NAME
    NEW_SQUAD_NAME="$(echo "$NEW_SQUAD_NAME" | sed -E 's/^ +| +$//g')"
    [[ -n "$NEW_SQUAD_NAME" ]] || { warn "Пустое имя — добавлю во все сквады."; SQUAD_MODE="ALL"; }
    ;;
  *)
    SQUAD_MODE="PICK"; picked=""
    for num in $SQ_CHOICE; do
      [[ "$num" =~ ^[0-9]+$ ]] && [[ -n "${SQ_UUID_ARR[$num]:-}" ]] && picked="${picked}${SQ_UUID_ARR[$num]},"
    done
    SQUAD_UUIDS="${picked%,}"
    [[ -n "$SQUAD_UUIDS" ]] || { warn "Ничего валидного не выбрано — добавлю во все сквады."; SQUAD_MODE="ALL"; }
    ;;
esac
log "Сквады: режим $SQUAD_MODE${NEW_SQUAD_NAME:+ ($NEW_SQUAD_NAME)}${SQUAD_UUIDS:+ [$SQUAD_UUIDS]}"

# ---------------------------------------------------------------------------
# Nginx + сертификат + заглушка (сначала серт — он нужен профилю)
# ---------------------------------------------------------------------------
CDN_PATH="/uploadfiles/"
log "Настраиваю Nginx и выпускаю сертификат..."
mkdir -p /etc/nginx/conf.d "$SSL_DIR" /var/www/certbot /var/www/html
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/hy2-ping.conf

if curl -fsSL "$DECOY_SITE_URL" -o /var/www/html/index.html 2>/dev/null && [[ -s /var/www/html/index.html ]]; then
  log "Заглушка скачана с GitHub."
else
  warn "Не смог скачать заглушку — кладу минимальную."
  echo '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>Service</title></head><body><h1>It works</h1></body></html>' > /var/www/html/index.html
fi
chown -R www-data:www-data /var/www/html

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { root /var/www/html; index index.html; }
}
EOF
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t >/dev/null 2>&1 || die "Базовый конфиг Nginx не проходит — nginx -t покажет причину"
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx

if [[ ! -d "/etc/letsencrypt/live/$NODE_DOMAIN" ]]; then
  log "Выпускаю ECDSA-сертификат Let's Encrypt для $NODE_DOMAIN..."
  certbot certonly --webroot -w /var/www/certbot -d "$NODE_DOMAIN" \
    --key-type ecdsa --non-interactive --agree-tos -m "admin@$NODE_DOMAIN" --no-eff-email \
    || warn "Certbot не смог получить сертификат"
else
  log "Сертификат для $NODE_DOMAIN уже есть — пропускаю выпуск."
fi
[[ -d "/etc/letsencrypt/live/$NODE_DOMAIN" ]] \
  || die "Без сертификата дальше нельзя (нужен Hysteria2 и CDN-origin). Поправь DNS, запусти заново."
cp "/etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem" "$SSL_DIR/cdn.crt"
cp "/etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem"   "$SSL_DIR/cdn.key"
chmod 644 "$SSL_DIR/cdn.crt"; chmod 600 "$SSL_DIR/cdn.key"

# ---------------------------------------------------------------------------
# SNI-донор (RealiTLScanner, fallback google)
# ---------------------------------------------------------------------------
SNI_DONOR="www.google.com"
SNI_CANDIDATES=("www.google.com" "www.microsoft.com" "www.apple.com" "swift.org")
log "Проверяю SNI-донора RealiTLScanner..."
SCANNER_BIN=""
if RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/XTLS/RealiTLScanner/releases/latest 2>/dev/null); then
  ASSET=$(echo "$RELEASE_JSON" | python3 -c "
import json,sys
try:
    for a in json.load(sys.stdin).get('assets',[]):
        n=a['name'].lower()
        if 'linux' in n and ('amd64' in n or 'x86_64' in n): print(a['browser_download_url']); break
except Exception: pass")
  if [[ -n "${ASSET:-}" ]]; then
    STMP=$(mktemp -d)
    if curl -fsSL "$ASSET" -o "$STMP/s.tar.gz" 2>/dev/null; then
      tar -xzf "$STMP/s.tar.gz" -C "$STMP" 2>/dev/null || true
      SCANNER_BIN=$(find "$STMP" -type f -iname "*realitlscanner*" 2>/dev/null | head -1)
      [[ -n "$SCANNER_BIN" ]] && chmod +x "$SCANNER_BIN"
    fi
  fi
fi
if [[ -n "$SCANNER_BIN" ]]; then
  for c in "${SNI_CANDIDATES[@]}"; do
    log "Проверяю $c..."
    if timeout 12 "$SCANNER_BIN" -addr "$c" -timeout 5 2>&1 | grep -q "feasible=true"; then
      SNI_DONOR="$c"; log "Подтверждён донор: $c."; break
    fi
  done
else
  warn "RealiTLScanner не получил — беру донор по умолчанию: $SNI_DONOR"
fi

# ---------------------------------------------------------------------------
# Свежий официальный Xray (кладём заранее, смонтируем в compose ноды)
# ---------------------------------------------------------------------------
log "Скачиваю свежий официальный Xray..."
mkdir -p "$NODE_DIR"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) XARCH="64" ;;
  aarch64|arm64) XARCH="arm64-v8a" ;;
  armv7l|armv7) XARCH="arm32-v7a" ;;
  *) XARCH="" ; warn "Необычная архитектура $ARCH_RAW — оставлю штатный Xray из образа." ;;
esac
XRAY_MOUNTED=false
if [[ -n "$XARCH" ]]; then
  XTMP="$(mktemp -d)"
  if curl -RL -H 'Cache-Control: no-cache' --max-time 120 -o "$XTMP/xray.zip" \
       "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$XARCH.zip" 2>/dev/null \
     && unzip -qo "$XTMP/xray.zip" xray -d "$XTMP" 2>/dev/null && [[ -f "$XTMP/xray" ]]; then
    install -m 755 "$XTMP/xray" "$XRAY_CUSTOM"
    XRAY_MOUNTED=true
    log "Xray: $("$XRAY_CUSTOM" version 2>/dev/null | head -1 || echo '?')"
  else
    warn "Не смог скачать Xray — нода поднимется со штатным. Позже: bash <(curl -fsSL $XRAY_INSTALLER_URL)"
  fi
  rm -rf "$XTMP"
fi

# ---------------------------------------------------------------------------
# Провижининг в панели: профиль (6 инбаундов) + СОЗДАНИЕ ноды + хосты + сквады
# ---------------------------------------------------------------------------
cat > /tmp/rw_deploy.py <<'DEPLOYEOF'
#!/usr/bin/env python3
"""Создаёт профиль, САМУ НОДУ (через API, забирает SECRET_KEY), хосты,
добавляет инбаунды в сквады. Печатает SECRET_KEY и UUID для bash. by qellyka"""
import json, os, re, sys, urllib.error, urllib.request

PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOKEN = os.environ["RW_API_TOKEN"]

def elog(m): print(m, file=sys.stderr)
def die(m): elog(f"[ERROR] {m}"); sys.exit(1)

def api(method, path, body=None, fatal=True):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(PANEL + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        t = e.read().decode(errors="replace")[:400]
        if fatal: die(f"{method} {path} -> HTTP {e.code}: {t}")
        return {"__error__": f"HTTP {e.code}: {t}"}
    except Exception as e:
        if fatal: die(f"{method} {path} -> {e}")
        return {"__error__": str(e)}

NODE_NAME = os.environ["RW_NODE_NAME"]
NODE_DOMAIN = os.environ["RW_NODE_DOMAIN"]
NODE_ADDRESS = os.environ.get("RW_NODE_ADDRESS") or NODE_DOMAIN
NODE_PORT = int(os.environ["RW_NODE_PORT"])
HOST_PREFIX = os.environ.get("RW_HOST_PREFIX", "").strip()
ENABLE_CDN = os.environ.get("RW_ENABLE_CDN") == "true"
ENABLE_BRIDGE = os.environ.get("RW_ENABLE_BRIDGE") == "true"
CDN_PUBLIC = os.environ.get("RW_CDN_PUBLIC_DOMAIN", "")
CDN_PATH = os.environ.get("RW_CDN_PATH", "/uploadfiles/")
P_TCP = int(os.environ["RW_PORT_REALITY_TCP"]); P_GRPC = int(os.environ["RW_PORT_REALITY_GRPC"])
P_XHTTP = int(os.environ["RW_PORT_REALITY_XHTTP"]); P_HY2 = int(os.environ["RW_PORT_HY2"])
P_CDN = int(os.environ["RW_PORT_CDN_LOCAL"]); P_BRIDGE = int(os.environ["RW_PORT_BRIDGE"])
SNI = os.environ.get("RW_SNI_DONOR", "www.google.com")
SUFFIX = os.environ["RW_TAG_SUFFIX"]

def remark(n): return f"{HOST_PREFIX} {n}" if HOST_PREFIX else n

elog("[1/7] Проверяю токен...")
r = api("GET", "/api/hosts", fatal=False)
if "__error__" in r:
    die(f"Токен не работает для /api/*: {r['__error__']}\n"
        "Если 403 'must create own API-token' — токен нулевого скоупа; пересоздай в UI.")
elog("      OK.")

# Ключи Reality: правильный эндпоинт возвращает МАССИВ из 30 пар. Берём 3.
def get_reality_keys(n):
    r = api("GET", "/api/system/tools/x25519/generate", fatal=False)
    if "__error__" not in r:
        b = r.get("response", r)
        kps = b.get("keypairs") if isinstance(b, dict) else None
        if kps and len(kps) >= n:
            return [kp["privateKey"] for kp in kps[:n]]
    # fallback: старые пути (одиночный ключ)
    for path in ("/api/system/x25519-key-pair", "/api/keygen/pub-key"):
        rr = api("GET", path, fatal=False)
        if "__error__" in rr: continue
        b = rr.get("response", rr)
        if isinstance(b, dict):
            priv = b.get("privateKey") or b.get("private_key")
            if priv: return [priv] * n
    die("Не смог получить ключи Reality (/api/system/tools/x25519/generate не ответил).")

elog("[2/7] Получаю ключи Reality...")
_rkeys = get_reality_keys(3)
tcp_key, grpc_key, xhttp_key = _rkeys[0], _rkeys[1], _rkeys[2]
tcp_sid = os.environ["RW_SID_TCP"]; grpc_sid = os.environ["RW_SID_GRPC"]; xhttp_sid = os.environ["RW_SID_XHTTP"]
xhttp_path = os.environ["RW_XHTTP_PATH"]

T_TCP, T_GRPC, T_XHTTP = f"reality-tcp-{SUFFIX}", f"reality-grpc-{SUFFIX}", f"reality-xhttp-{SUFFIX}"
T_HY2, T_CDN, T_BRIDGE = f"hysteria2-{SUFFIX}", f"cdn-xhttp-{SUFFIX}", f"bridge-in-{SUFFIX}"
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"]}

def reality(key, sid):
    return {"dest": f"{SNI}:443", "show": False, "xver": 0,
            "shortIds": [sid], "privateKey": key, "serverNames": [SNI]}

inbounds = [
    {"tag": T_TCP, "port": P_TCP, "listen": "0.0.0.0", "protocol": "vless",
     "settings": {"clients": [], "decryption": "none"}, "sniffing": SNIFF,
     "streamSettings": {"network": "tcp", "security": "reality",
                        "realitySettings": reality(tcp_key, tcp_sid)}},
    {"tag": T_GRPC, "port": P_GRPC, "listen": "::", "protocol": "vless",
     "settings": {"clients": [], "decryption": "none"},
     "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
     "streamSettings": {"network": "grpc", "security": "reality",
                        "grpcSettings": {"serviceName": "grpc"},
                        "realitySettings": reality(grpc_key, grpc_sid)}},
    {"tag": T_XHTTP, "port": P_XHTTP, "listen": "0.0.0.0", "protocol": "vless",
     "settings": {"clients": [], "decryption": "none"}, "sniffing": SNIFF,
     "streamSettings": {"network": "xhttp", "security": "reality",
                        "realitySettings": reality(xhttp_key, xhttp_sid),
                        "xhttpSettings": {"path": xhttp_path, "mode": "auto", "xPaddingBytes": "100-1000"}}},
    {"tag": T_HY2, "port": P_HY2, "listen": "::", "protocol": "hysteria",
     "settings": {"clients": [], "version": 2}, "sniffing": SNIFF,
     "streamSettings": {"network": "hysteria", "security": "tls",
                        "tlsSettings": {"alpn": ["h3"],
                            "certificates": [{"certificateFile": "/etc/nginx/ssl/cdn.crt",
                                              "keyFile": "/etc/nginx/ssl/cdn.key"}]}}},
]
if ENABLE_CDN:
    inbounds.append(
        {"tag": T_CDN, "port": P_CDN, "listen": "127.0.0.1", "protocol": "vless",
         "settings": {"clients": [], "decryption": "none"},
         "sniffing": {"enabled": True, "routeOnly": False, "destOverride": ["http", "tls", "quic"]},
         "streamSettings": {"network": "xhttp", "security": "none",
             "xhttpSettings": {"mode": "packet-up", "path": CDN_PATH,
                 "xPaddingKey": "_dc", "xPaddingHeader": "X-Cache", "xPaddingMethod": "tokenish",
                 "uplinkHTTPMethod": "get", "xPaddingObfsMode": True, "xPaddingPlacement": "queryInHeader"}}})
if ENABLE_BRIDGE:
    # Точная копия покупного BRIDGE_IN: vless/tcp/none, слушает 0.0.0.0:8888.
    # Вход для server-side routing — трафик приходит с ноды-источника.
    inbounds.append(
        {"tag": T_BRIDGE, "port": P_BRIDGE, "listen": "0.0.0.0", "protocol": "vless",
         "settings": {"clients": [], "decryption": "none"},
         "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
         "streamSettings": {"network": "tcp", "security": "none"}})

safe = re.sub(r"[^A-Za-z0-9_\s-]", "-", NODE_DOMAIN)
PROFILE_NAME = f"node-{safe}"[:30].rstrip("-")

elog(f"[3/7] Создаю Config Profile '{PROFILE_NAME}' ({len(inbounds)} инбаундов)...")
prof = api("POST", "/api/config-profiles", {
    "name": PROFILE_NAME,
    "config": {
        "log": {"loglevel": "warning"},
        "dns": {"servers": [{"address": "8.8.8.8", "skipFallback": False}], "queryStrategy": "UseIPv4"},
        "inbounds": inbounds,
        "outbounds": [{"tag": "direct", "protocol": "freedom"},
                      {"tag": "block", "protocol": "blackhole"}],
        "routing": {"rules": [
            {"ip": ["geoip:private"], "type": "field", "outboundTag": "direct"},
            {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}]},
    },
})["response"]
PROFILE_UUID = prof["uuid"]
tag_uuid = {ib["tag"]: ib["uuid"] for ib in prof["inbounds"]}
elog(f"      Профиль: {PROFILE_UUID}")

active_tags = [T_TCP, T_GRPC, T_XHTTP, T_HY2]
if ENABLE_CDN: active_tags.append(T_CDN)
if ENABLE_BRIDGE: active_tags.append(T_BRIDGE)
active_uuids = [tag_uuid[t] for t in active_tags]

elog("[4/7] Создаю НОДУ в панели...")
# Поля сверены с CreateNodeRequestDto (required: name, address, configProfile).
node_body = {
    "name": NODE_NAME,
    "address": NODE_ADDRESS,
    "port": NODE_PORT,
    "isTrafficTrackingActive": False,
    "trafficLimitBytes": 0,
    "trafficResetDay": 1,
    "notifyPercent": 0,
    "consumptionMultiplier": 1.0,
    "configProfile": {"activeConfigProfileUuid": PROFILE_UUID, "activeInbounds": active_uuids},
}
node = api("POST", "/api/nodes", node_body, fatal=False)
if "__error__" in node:
    die(f"Создание ноды не прошло: {node['__error__']}")
node = node["response"]
NODE_UUID = node.get("uuid") or node.get("nodeUuid")
if not NODE_UUID:
    die(f"Нода создана, но не вернулся uuid: {json.dumps(node)[:300]}")

# SECRET_KEY ноды — это НЕ секрет конкретной ноды, а общий для всей панели
# публичный ключ (SSL_CERT) из GET /api/keygen. Один на все ноды панели.
def get_node_secret():
    for path in ("/api/keygen", "/api/system/keygen", "/api/keygen/pub-key"):
        r = api("GET", path, fatal=False)
        if "__error__" in r: continue
        b = r.get("response", r)
        if isinstance(b, dict):
            for k in ("pubKey", "sslCert", "caCert", "cert", "certificate", "publicKey", "key"):
                v = b.get(k)
                if isinstance(v, str) and len(v) >= 24:
                    return v
            # иначе — первая длинная строка в ответе
            for v in b.values():
                if isinstance(v, str) and len(v) >= 40:
                    return v
        elif isinstance(b, str) and len(b) >= 40:
            return b
    return None

SECRET_KEY = get_node_secret()

# Привязка профиля, если ноду создавали без него (fallback-ветка выше).
cur_profile = (node.get("configProfile") or {}).get("activeConfigProfileUuid")
if cur_profile != PROFILE_UUID:
    nb = {"uuid": NODE_UUID, "configProfile": {"activeConfigProfileUuid": PROFILE_UUID,
          "activeInbounds": active_uuids}}
    res = api("PATCH", "/api/nodes", nb, fatal=False)
    if "__error__" in res: res = api("PATCH", f"/api/nodes/{NODE_UUID}", nb, fatal=False)
    if "__error__" in res: elog(f"      [WARN] профиль не привязался: {res['__error__']}")
elog(f"      Нода: {NODE_UUID}")

elog("[5/7] Создаю хосты...")
created = {}
def mkhost(tag, payload):
    payload["inbound"] = {"configProfileUuid": PROFILE_UUID, "configProfileInboundUuid": tag_uuid[tag]}
    r = api("POST", "/api/hosts", payload, fatal=False)
    if "__error__" in r:
        elog(f"      [WARN] {tag}: хост не создан — {r['__error__']}")
        return
    created[tag] = r["response"]["uuid"]; elog(f"      {tag} -> {r['response']['uuid']}")

mkhost(T_TCP, {"remark": remark("Reality TCP"), "address": NODE_DOMAIN, "port": P_TCP,
    "sni": SNI, "fingerprint": "chrome", "securityLayer": "DEFAULT"})
mkhost(T_GRPC, {"remark": remark("Reality gRPC"), "address": NODE_DOMAIN, "port": P_GRPC,
    "sni": SNI, "path": "grpc", "alpn": "h2", "fingerprint": "chrome", "securityLayer": "DEFAULT"})
mkhost(T_XHTTP, {"remark": remark("Reality XHTTP"), "address": NODE_DOMAIN, "port": P_XHTTP,
    "sni": SNI, "path": xhttp_path, "alpn": "h2,http/1.1", "fingerprint": "chrome", "securityLayer": "DEFAULT"})
mkhost(T_HY2, {"remark": remark("Hysteria2"), "address": NODE_DOMAIN, "port": P_HY2,
    "sni": NODE_DOMAIN, "alpn": "h3", "fingerprint": "random", "securityLayer": "TLS"})
if ENABLE_CDN:
    mkhost(T_CDN, {"remark": remark(f"CDN {CDN_PUBLIC}"), "address": CDN_PUBLIC, "port": 443,
        "sni": CDN_PUBLIC, "host": CDN_PUBLIC, "path": CDN_PATH, "alpn": "h3,h2,http/1.1",
        "fingerprint": "random", "securityLayer": "TLS",
        "xHttpExtraParams": {"mode": "packet-up", "xPaddingKey": "_dc", "xPaddingHeader": "X-Cache",
            "xPaddingMethod": "tokenish", "uplinkHTTPMethod": "get", "xPaddingObfsMode": True,
            "xPaddingPlacement": "queryInHeader"}})
# BRIDGE_IN — хост НЕ создаём: клиенты к нему не подключаются (это межнодовый вход).

# Выбор сквадов управляется из bash (меню после логина):
#   RW_SQUAD_MODE = ALL | PICK | NEW | NONE
#   RW_SQUAD_UUIDS = список UUID через запятую (для PICK)
#   RW_NEW_SQUAD_NAME = имя нового сквада (для NEW)
SQUAD_MODE = os.environ.get("RW_SQUAD_MODE", "ALL").upper()
SQUAD_UUIDS = [u for u in os.environ.get("RW_SQUAD_UUIDS", "").split(",") if u]
NEW_SQUAD_NAME = os.environ.get("RW_NEW_SQUAD_NAME", "").strip()

elog(f"[6/7] Сквады (режим: {SQUAD_MODE})...")
if SQUAD_MODE == "NONE":
    elog("      Пропускаю — инбаунды ни в один сквад не добавлены (включишь в UI).")
elif SQUAD_MODE == "NEW" and NEW_SQUAD_NAME:
    r = api("POST", "/api/internal-squads", {"name": NEW_SQUAD_NAME, "inbounds": active_uuids}, fatal=False)
    if "__error__" in r:
        elog(f"      [WARN] Не создал сквад '{NEW_SQUAD_NAME}': {r['__error__']}")
    else:
        newu = (r.get("response") or r).get("uuid", "?")
        elog(f"      Создан сквад '{NEW_SQUAD_NAME}' -> {newu} с {len(active_uuids)} инбаундами.")
else:
    sq = api("GET", "/api/internal-squads", fatal=False)
    done = False
    if "__error__" not in sq:
        b = sq.get("response", sq)
        squads = b.get("internalSquads") if isinstance(b, dict) else b
        if isinstance(b, dict) and squads is None: squads = b.get("data", [])
        for s in (squads or []):
            if SQUAD_MODE == "PICK" and s["uuid"] not in SQUAD_UUIDS:
                continue
            cur = [ib["uuid"] if isinstance(ib, dict) else ib for ib in (s.get("inbounds") or [])]
            merged = list(dict.fromkeys(cur + active_uuids))
            pl = {"uuid": s["uuid"], "name": s.get("name"), "inbounds": merged}
            r = api("PATCH", f"/api/internal-squads/{s['uuid']}", pl, fatal=False)
            if "__error__" in r: r = api("PATCH", "/api/internal-squads", pl, fatal=False)
            if "__error__" not in r: done = True; elog(f"      Squad '{s.get('name')}' обновлён.")
            else: elog(f"      [WARN] Squad '{s.get('name')}': {r['__error__']}")
    if not done:
        elog("      [WARN] Ни один сквад не обновлён — включи инбаунды в UI (Internal Squads).")

elog("[7/7] Готово (панель).")
# stdout — только машиночитаемое для bash:
out = {"nodeUuid": NODE_UUID, "profileUuid": PROFILE_UUID, "secretKey": SECRET_KEY or ""}
json.dump(out, open("/tmp/rw_deploy_result.json", "w"))
print(json.dumps(out))
DEPLOYEOF

TAG_SUFFIX="$(echo "$NODE_DOMAIN" | tr -cd 'A-Za-z0-9' | cut -c1-12)-$(openssl rand -hex 3)"
NODE_ADDRESS="${PUBLIC_IP:-$NODE_DOMAIN}"

log "Создаю профиль, ноду и хосты в панели..."
env RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN" \
  RW_NODE_NAME="$NODE_NAME" RW_NODE_DOMAIN="$NODE_DOMAIN" RW_NODE_ADDRESS="$NODE_ADDRESS" \
  RW_NODE_PORT="$NODE_PORT" RW_HOST_PREFIX="$HOST_PREFIX" RW_TAG_SUFFIX="$TAG_SUFFIX" \
  RW_SNI_DONOR="$SNI_DONOR" RW_ENABLE_CDN="$ENABLE_CDN" RW_ENABLE_BRIDGE="$ENABLE_BRIDGE" \
  RW_SQUAD_MODE="$SQUAD_MODE" RW_SQUAD_UUIDS="$SQUAD_UUIDS" RW_NEW_SQUAD_NAME="$NEW_SQUAD_NAME" \
  RW_CDN_PUBLIC_DOMAIN="$CDN_PUBLIC_DOMAIN" RW_CDN_PATH="$CDN_PATH" \
  RW_PORT_REALITY_TCP="$PORT_REALITY_TCP" RW_PORT_REALITY_GRPC="$PORT_REALITY_GRPC" \
  RW_PORT_REALITY_XHTTP="$PORT_REALITY_XHTTP" RW_PORT_HY2="$PORT_HY2" \
  RW_PORT_CDN_LOCAL="$PORT_CDN_LOCAL" RW_PORT_BRIDGE="$PORT_BRIDGE" \
  RW_SID_TCP="$(openssl rand -hex 8)" RW_SID_GRPC="$(openssl rand -hex 8)" \
  RW_SID_XHTTP="$(openssl rand -hex 8)" RW_XHTTP_PATH="/$(openssl rand -hex 8)/" \
  python3 /tmp/rw_deploy.py || die "Провижининг в панели не прошёл (см. ошибку выше)."

NODE_UUID=$(python3 -c "import json;print(json.load(open('/tmp/rw_deploy_result.json'))['nodeUuid'])")
PROFILE_UUID=$(python3 -c "import json;print(json.load(open('/tmp/rw_deploy_result.json'))['profileUuid'])")
SECRET_KEY=$(python3 -c "import json;print(json.load(open('/tmp/rw_deploy_result.json'))['secretKey'])")

# SECRET_KEY (общий ключ панели из /api/keygen) мог не прийти — попросим из UI.
if [[ -z "$SECRET_KEY" ]]; then
  warn "Панель не отдала ключ через /api/keygen (зависит от версии)."
  echo "Возьми его в панели: любая нода -> 'Copy docker-compose.yml' (значение SECRET_KEY),"
  echo "либо страница генерации ключа. Он одинаков для всех нод этой панели."
  read -rp "SECRET_KEY: " SECRET_KEY
  SECRET_KEY="$(echo "$SECRET_KEY" | tr -d '[:space:]\"')"
  [[ -n "$SECRET_KEY" ]] || die "Без SECRET_KEY нода не подключится."
fi
rm -f /tmp/rw_deploy.py

# ---------------------------------------------------------------------------
# docker-compose.yml ноды + запуск
# ---------------------------------------------------------------------------
log "Пишу docker-compose.yml ноды и поднимаю контейнер..."
XRAY_VOL=""
[[ "$XRAY_MOUNTED" == "true" ]] && XRAY_VOL="      - $XRAY_CUSTOM:/usr/local/bin/xray"
cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
EOF
chmod 600 "$NODE_DIR/.env"
cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: $NODE_IMAGE
    restart: always
    network_mode: host
    env_file:
      - .env
    volumes:
      - /etc/nginx/ssl:/etc/nginx/ssl:ro
$XRAY_VOL
EOF
# убрать пустую строку, если Xray не монтируем
sed -i '/^$/d' "$NODE_DIR/docker-compose.yml"
( cd "$NODE_DIR" && docker compose up -d ) || warn "docker compose up вернул ошибку — проверь: docker logs remnanode"

# ---------------------------------------------------------------------------
# Боевой Nginx (заглушка + камуфляж 8443 + origin CDN)
# ---------------------------------------------------------------------------
log "Пишу боевой конфиг Nginx..."
cat > /etc/nginx/conf.d/hy2-ping.conf <<EOF
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name _;
    ssl_certificate     $SSL_DIR/cdn.crt;
    ssl_certificate_key $SSL_DIR/cdn.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { return 200 'ok'; }
}
EOF
{
  if [[ "$ENABLE_CDN" == "true" ]]; then
    echo "upstream xray_xhttp { server 127.0.0.1:$PORT_CDN_LOCAL; keepalive 128; }"
  fi
  cat <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;

    ssl_certificate     $SSL_DIR/cdn.crt;
    ssl_certificate_key $SSL_DIR/cdn.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location /.well-known/acme-challenge/ { root /var/www/certbot; }

    location = /health {
        default_type application/json;
        return 200 '{"status":"ok","service":"media-gateway","version":"4.2.1"}';
    }
EOF
  if [[ "$ENABLE_CDN" == "true" ]]; then
    cat <<EOF

    location = /uploadfiles { return 404; }
    location /uploadfiles/ {
        proxy_pass http://xray_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass_request_headers on;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_max_temp_file_size 0;
        gzip off;
        proxy_connect_timeout 10s;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        send_timeout 1h;
        client_max_body_size 0;
        proxy_socket_keepalive on;
        add_header X-Accel-Buffering no always;
        add_header Cache-Control "no-store, no-cache" always;
        add_header CDN-Cache-Control "no-store" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;
        add_header Accept-Ranges none always;
    }
EOF
  fi
  cat <<EOF

    location / {
        root /var/www/html;
        index index.html;
        try_files \$uri \$uri/ =404;
    }
}
EOF
} > /etc/nginx/sites-available/default
nginx -t || die "Итоговый конфиг Nginx не проходит проверку"
systemctl reload nginx 2>/dev/null || systemctl restart nginx
log "Nginx готов: https://$NODE_DOMAIN отдаёт заглушку."

# ---------------------------------------------------------------------------
# Firewall — политика drop совместима (правила в существующую inet filter input)
# ---------------------------------------------------------------------------
FW_TCP="$PORT_REALITY_TCP, $PORT_REALITY_GRPC, $PORT_REALITY_XHTTP, 80, 443, 8443"
BRIDGE_RULES=""
if [[ "$ENABLE_BRIDGE" == "true" ]]; then
  if [[ -n "$BRIDGE_PEERS" ]]; then
    for ip in $BRIDGE_PEERS; do
      BRIDGE_RULES="${BRIDGE_RULES}nft insert rule inet filter input ip saddr $ip tcp dport $PORT_BRIDGE accept comment \"rw-node-bridge\"
"
    done
  else
    BRIDGE_RULES="nft insert rule inet filter input tcp dport $PORT_BRIDGE accept comment \"rw-node-bridge\"
"
  fi
fi
NODEPORT_RULE=""
if [[ -n "$PANEL_IP" ]]; then
  NODEPORT_RULE="nft insert rule inet filter input ip saddr $PANEL_IP tcp dport $NODE_PORT accept comment \"rw-node-nodeport\""
else
  NODEPORT_RULE="nft insert rule inet filter input tcp dport $NODE_PORT accept comment \"rw-node-nodeport\""
fi

if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then
  log "Открываю порты в nftables..."
  cat > /usr/local/bin/rw-node-firewall.sh <<EOF
#!/usr/bin/env bash
set -u
nft list table inet filter >/dev/null 2>&1 || exit 0
nft list chain inet filter input 2>/dev/null | grep -q "rw-node" && exit 0
nft insert rule inet filter input udp dport $PORT_HY2 accept comment "rw-node"
nft insert rule inet filter input tcp dport { $FW_TCP } accept comment "rw-node"
$NODEPORT_RULE
$BRIDGE_RULES
EOF
  chmod +x /usr/local/bin/rw-node-firewall.sh
  /usr/local/bin/rw-node-firewall.sh || warn "Не смог добавить правила nftables — проверь вручную"
  cat > /etc/systemd/system/rw-node-firewall.service <<'EOF'
[Unit]
Description=Remnawave node firewall ports
After=nftables.service docker.service
Wants=nftables.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rw-node-firewall.sh
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable rw-node-firewall.service >/dev/null 2>&1 || true
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "Открываю порты в ufw..."
  for p in $PORT_REALITY_TCP $PORT_REALITY_GRPC $PORT_REALITY_XHTTP 80 443 8443; do ufw allow "$p"/tcp >/dev/null 2>&1 || true; done
  ufw allow "$PORT_HY2"/udp >/dev/null 2>&1 || true
  if [[ -n "$PANEL_IP" ]]; then ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null 2>&1 || true
  else ufw allow "$NODE_PORT"/tcp >/dev/null 2>&1 || true; fi
  if [[ "$ENABLE_BRIDGE" == "true" ]]; then
    if [[ -n "$BRIDGE_PEERS" ]]; then for ip in $BRIDGE_PEERS; do ufw allow from "$ip" to any port "$PORT_BRIDGE" proto tcp >/dev/null 2>&1 || true; done
    else ufw allow "$PORT_BRIDGE"/tcp >/dev/null 2>&1 || true; fi
  fi
else
  warn "Активный фаервол не обнаружен — открой сам: TCP $FW_TCP, UDP $PORT_HY2, NODE_PORT $NODE_PORT (только с $PANEL_IP)"
fi

# ---------------------------------------------------------------------------
# Хук продления сертификата
# ---------------------------------------------------------------------------
log "Ставлю хук продления сертификата..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/rw-hy2-cert.sh <<EOF
#!/bin/bash
cp /etc/letsencrypt/live/$NODE_DOMAIN/fullchain.pem $SSL_DIR/cdn.crt
cp /etc/letsencrypt/live/$NODE_DOMAIN/privkey.pem   $SSL_DIR/cdn.key
chmod 600 $SSL_DIR/cdn.key
nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || true
docker restart remnanode 2>/dev/null || true
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/rw-hy2-cert.sh

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
echo ""
echo "==================================================="
echo "  Готово — нода установлена с нуля"
echo "==================================================="
echo "Нода:    $NODE_NAME ($NODE_UUID)"
echo "Домен:   https://$NODE_DOMAIN  (заглушка)"
echo "Профиль: $PROFILE_UUID"
echo "SNI-донор Reality: $SNI_DONOR"
echo ""
echo "Инбаунды:"
echo "  Reality TCP (Vision)  TCP  $PORT_REALITY_TCP"
echo "  Reality gRPC          TCP  $PORT_REALITY_GRPC"
echo "  Reality XHTTP         TCP  $PORT_REALITY_XHTTP  (не проверен вживую — бонусный)"
echo "  Hysteria2             UDP  $PORT_HY2"
[[ "$ENABLE_CDN" == "true" ]] && echo "  CDN XHTTP             Yandex CDN -> Nginx -> 127.0.0.1:$PORT_CDN_LOCAL"
[[ "$ENABLE_BRIDGE" == "true" ]] && echo "  BRIDGE_IN             TCP  $PORT_BRIDGE  (межнодовый; в подписку не идёт)"
echo ""
echo "Проверь: docker logs remnanode --tail 50   и статус ноды в панели (connected)."
if [[ "$ENABLE_BRIDGE" == "true" ]]; then
hr
echo "BRIDGE_IN включён. Чтобы мост заработал, на НОДЕ-ИСТОЧНИКЕ нужен"
echo "outbound + правило маршрутизации, указывающие на $NODE_DOMAIN:$PORT_BRIDGE."
echo "Порт $PORT_BRIDGE открыт${BRIDGE_PEERS:+ только для: $BRIDGE_PEERS}."
[[ -z "$BRIDGE_PEERS" ]] && echo "!! Ты открыл $PORT_BRIDGE всем — ограничь его IP источников."
fi
if [[ "$ENABLE_CDN" == "true" ]]; then
hr
echo "ОСТАЛОСЬ РУКАМИ — ресурс в Yandex Cloud CDN:"
echo "1. Certificate Manager -> LE-сертификат для $CDN_PUBLIC_DOMAIN (DNS-валидация)."
echo "2. CDN -> Группы источников -> источник: $NODE_DOMAIN, HTTPS."
echo "3. CDN -> Ресурсы -> создать: домен $CDN_PUBLIC_DOMAIN, источник из шага 2,"
echo "   сертификат из шага 1, протокол к источнику HTTPS,"
echo "   Host-заголовок = $NODE_DOMAIN, кэш ВЫКЛ, сжатие ВЫКЛ."
echo "4. CNAME $CDN_PUBLIC_DOMAIN -> <домен из консоли CDN, вида cl-xxxxx.edgecdn.ru>."
echo "Путь XHTTP: $CDN_PATH"
fi
echo "==================================================="
