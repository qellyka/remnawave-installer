#!/usr/bin/env bash
# Remnawave — установка ноды с НУЛЯ на чистом сервере — by qellyka
#
# Заходишь на чистый Ubuntu/Debian, запускаешь — скрипт делает всё сам:
#   - ставит Docker + Compose, если их нет;
#   - авторизуется в панели API-токеном (или пробует выпустить его из логина);
#   - выпускает сертификат, ставит Nginx + сайт-заглушку;
#   - создаёт в панели профиль (Reality gRPC, Reality XHTTP, Hysteria2,
#     опционально CDN-XHTTP через Yandex CDN и BRIDGE_IN) и саму ноду;
#   - разворачивает контейнер remnanode и ждёт, пока панель его увидит;
#   - создаёт хосты с именами вида "🇩🇪 DE | Reality gRPC", добавляет
#     инбаунды в сквады;
#   - открывает порты (NODE_PORT — только для IP панели);
#   - ставит хук продления сертификата.
#
# Авторизация в v3: данные (/api/nodes, /api/hosts, ...) принимают ТОЛЬКО
# API-токен (Settings -> API Tokens). Админский JWT из логина там даёт 403.
# Токен кладётся в /root/.rw_node_token (chmod 600) для повторных прогонов.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }
hr()   { echo "---------------------------------------------------"; }

[[ $EUID -eq 0 ]] || die "Запускай от root (sudo)."

# Все временные файлы (в т.ч. с токеном и SECRET_KEY) — в приватной папке,
# которая удаляется при любом выходе.
umask 022
WORK_DIR="$(mktemp -d /tmp/rw-deploy.XXXXXX)"
chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT
TOKEN_FILE="/root/.rw_node_token"

DECOY_SITE_URL="https://raw.githubusercontent.com/qellyka/remnawave-installer/main/index.html"
NODE_DIR="/opt/remnanode"
SSL_DIR="/etc/nginx/ssl"
NODE_IMAGE="ghcr.io/remnawave/node:latest"

# Порты инбаундов — покупная схема + мост.
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
echo "  Remnawave — установка ноды с НУЛЯ"
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
AUTH_CHOICE=""
API_TOKEN=""; RW_LOGIN=""; RW_PASSWORD=""
if [[ -s "$TOKEN_FILE" ]]; then
  read -rp "Нашёл сохранённый API-токен ($TOKEN_FILE). Использовать его? [Y/n]: " USE_SAVED
  if [[ ! "$USE_SAVED" =~ ^[Nn]$ ]]; then
    API_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    AUTH_CHOICE="saved"
  fi
fi
if [[ -z "$AUTH_CHOICE" ]]; then
echo "Авторизация в панели:"
echo "  1) Готовый API-токен — СОЗДАЙ его в UI: Settings -> API Tokens (рекомендуется)"
echo "  2) Логин + пароль (скрипт попробует выпустить токен сам — многие панели"
echo "     это ЗАПРЕЩАЮТ и вернут 403 'must create own API-token')"
read -rp "Введите номер [1-2]: " AUTH_CHOICE
if [[ "$AUTH_CHOICE" == "2" ]]; then
  read -rp "Логин администратора панели: " RW_LOGIN
  read -rsp "Пароль администратора: " RW_PASSWORD; echo
  [[ -n "$RW_LOGIN" && -n "$RW_PASSWORD" ]] || die "Логин и пароль обязательны"
else
  read -rp "API-токен: " API_TOKEN
  API_TOKEN="$(echo "$API_TOKEN" | tr -d '[:space:]')"
  [[ -n "$API_TOKEN" ]] || die "Токен пуст"
fi
fi

read_clean "Имя ноды в панели (например DE-1): " NODE_NAME 'A-Za-z0-9 _.-'
[[ -n "$NODE_NAME" ]] || NODE_NAME="node-$(date +%s)"

hr
echo "Домен этой ноды — на него сертификат, заглушка, origin CDN, SNI Hy2."
read_clean "Домен ноды (например de1.example.com): " NODE_DOMAIN 'A-Za-z0-9.-'
[[ -n "$NODE_DOMAIN" ]] || die "Домен обязателен"

hr
echo "Публичный домен CDN (Yandex CDN) — Enter, чтобы пропустить (без CDN-инбаунда)."
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
echo "Код страны ноды (2 буквы, например DE, PL, FI) — из него соберу имена"
echo "хостов вида \"🇩🇪 DE | Reality gRPC\". Такой формат подхватывает шаблон"
echo "автовыбора (remarkRegex ^\\S+\\s+[A-Z]{2}\\s*\\|)."
read_clean "Код страны (Enter — без префикса): " COUNTRY_CODE 'A-Za-z'
COUNTRY_CODE="$(echo "$COUNTRY_CODE" | tr '[:lower:]' '[:upper:]' | cut -c1-2)"
HOST_PREFIX=""
if [[ ${#COUNTRY_CODE} -eq 2 ]]; then
  FLAG="$(python3 -c "import sys;print(''.join(chr(0x1F1E6+ord(c)-65) for c in sys.argv[1]))" "$COUNTRY_CODE" 2>/dev/null || true)"
  HOST_PREFIX="${FLAG:+$FLAG }$COUNTRY_CODE |"
  log "Префикс хостов: \"$HOST_PREFIX\""
else
  read -rp "Свой префикс к именам хостов (Enter — без префикса): " HOST_PREFIX
fi
read -rp "Имя CDN-хоста [LTE]: " CDN_HOST_NAME
CDN_HOST_NAME="${CDN_HOST_NAME:-LTE}"

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
# Если панель за Cloudflare/CDN, DNS отдаёт IP прокси, а не сервера панели —
# тогда правило на NODE_PORT заблокирует саму панель. Даём поправить.
echo "IP сервера ПАНЕЛИ (с него панель ходит на NODE_PORT $NODE_PORT)."
echo "Если панель за Cloudflare/CDN — DNS покажет не тот IP, впиши реальный."
read -rp "IP панели [${PANEL_IP:-не определён}] (Enter — принять, 'any' — открыть всем): " _pip
_pip="$(echo "$_pip" | tr -d '[:space:]')"
if [[ "$_pip" == "any" ]]; then PANEL_IP=""
elif [[ -n "$_pip" ]]; then PANEL_IP="$_pip"; fi
if [[ -n "$PANEL_IP" ]]; then
  log "NODE_PORT $NODE_PORT будет открыт только для $PANEL_IP."
else
  warn "NODE_PORT $NODE_PORT будет открыт ВСЕМ — ограничь его позже."
fi

# Версия xray в образе ноды -> minClientVer (отсекает старые Reality-клиенты).
# Можно задать руками: MIN_CLIENT_VER=26.7.28 bash remnanode-deploy.sh
# (MIN_CLIENT_VER=none — не ограничивать).
log "Скачиваю образ ноды..."
docker pull "$NODE_IMAGE" >/dev/null 2>&1 || warn "docker pull не прошёл — попробую с тем, что есть."
if [[ -n "${MIN_CLIENT_VER:-}" ]]; then
  [[ "$MIN_CLIENT_VER" == "none" ]] && MIN_CLIENT_VER=""
  log "minClientVer задан вручную: ${MIN_CLIENT_VER:-без ограничения}"
  _ver="manual"
else
MIN_CLIENT_VER="26.7.28"   # фолбэк, если не удалось определить
log "Определяю версию Xray в образе ноды (для minClientVer)..."
# || true обязателен: при set -o pipefail пустой grep иначе молча роняет скрипт.
_ver=$(docker run --rm --entrypoint /usr/local/bin/xray "$NODE_IMAGE" version 2>/dev/null \
  | grep -oE 'Xray [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}' || true)
fi
if [[ "$_ver" == "manual" ]]; then
  :
elif [[ "$_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  MIN_CLIENT_VER="$_ver"; log "minClientVer = $MIN_CLIENT_VER (ядро ноды)."
else
  warn "Не определил версию Xray — беру minClientVer=$MIN_CLIENT_VER по умолчанию."
fi

# ---------------------------------------------------------------------------
# Авторизация
# ---------------------------------------------------------------------------
if [[ "$AUTH_CHOICE" == "2" ]]; then
  cat > "$WORK_DIR/mint.py" <<'MINTEOF'
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
    python3 "$WORK_DIR/mint.py") \
    || die "Не удалось выпустить токен. Создай его в UI (Settings -> API Tokens) и запусти заново с вариантом 1."
  unset RW_PASSWORD
  rm -f "$WORK_DIR/mint.py"
  log "API-токен получен."
fi

# Проверяем токен (обе ветки): реальный вызов к /api/*.
cat > "$WORK_DIR/check.py" <<'CHKEOF'
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
export RW_PANEL_URL="$PANEL_URL" RW_API_TOKEN="$API_TOKEN"
python3 "$WORK_DIR/check.py" \
  || die "Токен не работает (см. выше). Если это сохранённый токен — удали $TOKEN_FILE и запусти заново."
rm -f "$WORK_DIR/check.py"
log "Токен рабочий."

# Сохраним токен для повторных прогонов (chmod 600).
( umask 077; printf '%s\n' "$API_TOKEN" > "$TOKEN_FILE" )

# ---------------------------------------------------------------------------
# Выбор Internal Squad'ов (в какие добавить инбаунды ноды)
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/squads.py" <<'SQEOF'
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
SQUADS_LIST=$(python3 "$WORK_DIR/squads.py" 2>/dev/null || true)
rm -f "$WORK_DIR/squads.py"
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
    --key-type ecdsa --non-interactive --agree-tos --register-unsafely-without-email \
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
# SNI-донор Reality: проверяем кандидатов openssl'ом (TLS 1.3 + h2 + X25519)
# и берём самого быстрого. Без скачивания сканера и без сканирования подсетей
# (RealiTLScanner сам предупреждает, что сканы с VPS могут пометить сервер).
# ---------------------------------------------------------------------------
SNI_CANDIDATES=("www.google.com" "www.microsoft.com" "www.apple.com" "dl.google.com" "www.amazon.com" "swift.org")
SNI_DONOR=""; _best_ms=999999
log "Выбираю SNI-донора Reality..."
for c in "${SNI_CANDIDATES[@]}"; do
  _t0=$(date +%s%N)
  _out=$(timeout 8 openssl s_client -connect "$c:443" -servername "$c" -tls1_3 \
          -alpn h2 -groups X25519 </dev/null 2>/dev/null || true)
  _ms=$(( ($(date +%s%N) - _t0) / 1000000 ))
  if grep -q "TLSv1.3" <<<"$_out" && grep -q "ALPN protocol: h2" <<<"$_out"; then
    log "  $c — годится (${_ms} мс)"
    if (( _ms < _best_ms )); then _best_ms=$_ms; SNI_DONOR="$c"; fi
  else
    log "  $c — не подходит"
  fi
done
if [[ -z "$SNI_DONOR" ]]; then
  SNI_DONOR="www.google.com"; warn "Ни один кандидат не прошёл проверку — беру $SNI_DONOR."
else
  log "SNI-донор: $SNI_DONOR"
fi

# ---------------------------------------------------------------------------
# Xray НЕ подменяем. Образ node:latest уже несёт совместимый xray, а нода
# отдаёт ему конфиг через свой внутренний механизм (@rwint.../internal/
# get-config). Подмонтированный сторонний бинарник этот механизм не понимает
# и падает (exitcode 23, "failed to load config @rwint..."). Дока Remnawave
# прямо не советует монтировать своё в xray. Нужна особая версия — ставь
# официальным способом:
#   bash <(curl -fsSL https://raw.githubusercontent.com/remnawave/scripts/main/scripts/install-latest-xray.sh)
mkdir -p "$NODE_DIR"

# ---------------------------------------------------------------------------
# Провижининг в панели: профиль (6 инбаундов) + СОЗДАНИЕ ноды + хосты + сквады
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/deploy.py" <<'DEPLOYEOF'
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
P_GRPC = int(os.environ["RW_PORT_REALITY_GRPC"])
P_XHTTP = int(os.environ["RW_PORT_REALITY_XHTTP"]); P_HY2 = int(os.environ["RW_PORT_HY2"])
P_CDN = int(os.environ["RW_PORT_CDN_LOCAL"]); P_BRIDGE = int(os.environ["RW_PORT_BRIDGE"])
SNI = os.environ.get("RW_SNI_DONOR", "www.google.com")
SUFFIX = os.environ["RW_TAG_SUFFIX"]

def remark(n): return f"{HOST_PREFIX} {n}" if HOST_PREFIX else n

PROFILE_UUID = None
def rollback_and_die(msg):
    # Нода не создалась — убираем свежий профиль, чтобы не копились сироты.
    if PROFILE_UUID:
        r = api("DELETE", f"/api/config-profiles/{PROFILE_UUID}", fatal=False)
        if "__error__" in r:
            elog(f"  [WARN] не смог удалить профиль {PROFILE_UUID}: {r['__error__']}")
        else:
            elog(f"  Откатил: профиль {PROFILE_UUID} удалён.")
    die(msg)

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
# Reality нужен для gRPC и XHTTP (по 1 ключу). TCP+Vision убран — не работает.
_rkeys = get_reality_keys(2)
grpc_key = _rkeys[0]
xhttp_key = _rkeys[1]
grpc_sid = os.environ["RW_SID_GRPC"]; xhttp_sid = os.environ["RW_SID_XHTTP"]
xhttp_path = os.environ["RW_XHTTP_PATH"]

T_GRPC, T_XHTTP = f"reality-grpc-{SUFFIX}", f"reality-xhttp-{SUFFIX}"
T_HY2, T_CDN, T_BRIDGE = f"hysteria2-{SUFFIX}", f"cdn-xhttp-{SUFFIX}", f"bridge-in-{SUFFIX}"
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"]}

MIN_CLIENT_VER = os.environ.get("RW_MIN_CLIENT_VER", "26.7.28")

def reality(key, sid):
    # minClientVer — только Reality: отсекает старые xray-клиенты (иначе их
    # неудачные попытки временно роняют инбаунд). Значение = ядро ноды.
    r = {"dest": f"{SNI}:443", "show": False, "xver": 0,
         "shortIds": [sid], "privateKey": key, "serverNames": [SNI]}
    if MIN_CLIENT_VER:
        r["minClientVer"] = MIN_CLIENT_VER
    return r

# Рабочий набор (проверено вживую на клиенте Happ): gRPC, Hysteria2,
# Reality-XHTTP, + CDN-XHTTP через Yandex. Reality-TCP+Vision убран целиком —
# не поднимается ни в одном клиенте.
inbounds = [
    # gRPC + Reality — проверено, работает везде
    {"tag": T_GRPC, "port": P_GRPC, "listen": "::", "protocol": "vless",
     "settings": {"clients": [], "decryption": "none"},
     "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
     "streamSettings": {"network": "grpc", "security": "reality",
                        "grpcSettings": {"serviceName": "grpc"},
                        "realitySettings": reality(grpc_key, grpc_sid)}},
    # Hysteria2 — из покупного (серт файлом, alpn h3); нужен UDP-порт открыт
    {"tag": T_HY2, "port": P_HY2, "listen": "::", "protocol": "hysteria",
     "settings": {"clients": [], "version": 2}, "sniffing": SNIFF,
     "streamSettings": {"network": "hysteria", "security": "tls",
                        "tlsSettings": {"alpn": ["h3"],
                            "certificates": [{"certificateFile": "/etc/nginx/ssl/cdn.crt",
                                              "keyFile": "/etc/nginx/ssl/cdn.key"}]}}},
    # Reality + XHTTP (прямой) — работает на свежих клиентах (Happ и т.п.)
    {"tag": T_XHTTP, "port": P_XHTTP, "listen": "0.0.0.0", "protocol": "vless",
     "settings": {"clients": [], "decryption": "none"}, "sniffing": SNIFF,
     "streamSettings": {"network": "xhttp", "security": "reality",
                        "realitySettings": reality(xhttp_key, xhttp_sid),
                        "xhttpSettings": {"path": xhttp_path, "mode": "auto", "xPaddingBytes": "100-1000"}}},
]
# CDN-XHTTP через Yandex — из покупного (главный инбаунд под обход DPI)
if ENABLE_CDN:
    inbounds.append(
        {"tag": T_CDN, "port": P_CDN, "listen": "127.0.0.1", "protocol": "vless",
         "settings": {"clients": [], "decryption": "none"},
         "sniffing": {"enabled": True, "routeOnly": False, "destOverride": ["http", "tls", "quic"]},
         "streamSettings": {"network": "xhttp", "security": "none",
             "xhttpSettings": {"mode": "packet-up", "path": CDN_PATH,
                 "xPaddingKey": "_dc", "xPaddingHeader": "X-Cache", "xPaddingMethod": "tokenish",
                 "uplinkHTTPMethod": "GET", "xPaddingObfsMode": True, "xPaddingPlacement": "queryInHeader"}}})
if ENABLE_BRIDGE:
    # Точная копия покупного BRIDGE_IN: vless/tcp/none, слушает 0.0.0.0:8888.
    # Вход для server-side routing — трафик приходит с ноды-источника.
    inbounds.append(
        {"tag": T_BRIDGE, "port": P_BRIDGE, "listen": "0.0.0.0", "protocol": "vless",
         "settings": {"clients": [], "decryption": "none"},
         "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
         "streamSettings": {"network": "tcp", "security": "none"}})

safe = re.sub(r"[^A-Za-z0-9_\s-]", "-", NODE_DOMAIN)
rnd = (SUFFIX.split("-")[-1] or os.urandom(3).hex())[:6]
# Уникальное имя (домен + рандом) — чтобы повторный прогон не ловил 409.
PROFILE_NAME = (f"node-{safe}"[:23].rstrip("-")) + "-" + rnd

profile_config = {
    "log": {"loglevel": "warning"},
    "dns": {"servers": [{"address": "8.8.8.8", "skipFallback": False}], "queryStrategy": "UseIPv4"},
    "inbounds": inbounds,
    "outbounds": [{"tag": "direct", "protocol": "freedom"},
                  {"tag": "block", "protocol": "blackhole"}],
    "routing": {"rules": [
        # Клиенты НЕ должны ходить в локальную сеть/метадату сервера (169.254.169.254 и т.п.)
        {"ip": ["geoip:private"], "type": "field", "outboundTag": "block"},
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}]},
}
elog(f"[3/7] Создаю Config Profile '{PROFILE_NAME}' ({len(inbounds)} инбаундов)...")
prof = None
for attempt in range(4):
    r = api("POST", "/api/config-profiles", {"name": PROFILE_NAME, "config": profile_config}, fatal=False)
    if "__error__" not in r:
        prof = r["response"]; break
    if "409" in r["__error__"] or "already exists" in r["__error__"]:
        PROFILE_NAME = (f"node-{safe}"[:19].rstrip("-")) + "-" + os.urandom(3).hex()
        elog(f"      имя занято, пробую '{PROFILE_NAME}'...")
        continue
    die(f"POST /api/config-profiles -> {r['__error__']}")
if prof is None:
    die("Не смог создать Config Profile (имя постоянно занято).")
PROFILE_UUID = prof["uuid"]
tag_uuid = {ib["tag"]: ib["uuid"] for ib in prof["inbounds"]}
elog(f"      Профиль: {PROFILE_UUID}")

active_tags = [T_GRPC, T_XHTTP, T_HY2]
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
node = None
_orig_name = NODE_NAME
for attempt in range(3):
    node_body["name"] = NODE_NAME
    r = api("POST", "/api/nodes", node_body, fatal=False)
    if "__error__" not in r:
        node = r["response"]; break
    err = r["__error__"]
    low = err.lower()
    if ("409" in err or "already exists" in low) and ("name" in low and "address" not in low):
        NODE_NAME = f"{_orig_name}-{os.urandom(2).hex()}"
        elog(f"      имя ноды занято, пробую '{NODE_NAME}'...")
        continue
    if "409" in err or "already exists" in low:
        rollback_and_die("Нода с таким адресом уже есть в панели (возможно, твоя рабочая/покупная нода "
            f"на {NODE_ADDRESS}). Скрипт НЕ трогает её, чтобы не сломать. Удали тестовую "
            "ноду в панели или ставь на другой сервер/адрес. Ответ: " + err)
    rollback_and_die(f"Создание ноды не прошло: {err}")
if node is None:
    rollback_and_die("Не смог создать ноду (имя постоянно занято).")
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

mkhost(T_GRPC, {"remark": remark("Reality gRPC"), "address": NODE_DOMAIN, "port": P_GRPC,
    "sni": SNI, "path": "grpc", "alpn": "h2", "fingerprint": "chrome", "securityLayer": "DEFAULT"})
mkhost(T_XHTTP, {"remark": remark("Reality XHTTP"), "address": NODE_DOMAIN, "port": P_XHTTP,
    "sni": SNI, "path": xhttp_path, "alpn": "h2,http/1.1", "fingerprint": "chrome", "securityLayer": "DEFAULT"})
mkhost(T_HY2, {"remark": remark("Hysteria2"), "address": NODE_DOMAIN, "port": P_HY2,
    "sni": NODE_DOMAIN, "alpn": "h3", "fingerprint": "random", "securityLayer": "TLS"})
if ENABLE_CDN:
    mkhost(T_CDN, {"remark": remark(os.environ.get("RW_CDN_HOST_NAME") or "LTE"), "address": CDN_PUBLIC, "port": 443,
        "sni": CDN_PUBLIC, "host": CDN_PUBLIC, "path": CDN_PATH, "alpn": "h3,h2,http/1.1",
        "fingerprint": "random", "securityLayer": "TLS",
        "xhttpExtraParams": {"mode": "packet-up", "xPaddingKey": "_dc", "xPaddingHeader": "X-Cache",
            "xPaddingMethod": "tokenish", "uplinkHTTPMethod": "GET", "xPaddingObfsMode": True,
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
    if "__error__" not in r:
        newu = (r.get("response") or r).get("uuid", "?")
        elog(f"      Создан сквад '{NEW_SQUAD_NAME}' -> {newu} с {len(active_uuids)} инбаундами.")
    elif "409" in r["__error__"] or "already exists" in r["__error__"].lower():
        # Сквад с таким именем уже есть (повторный прогон) — до-мержим в него.
        elog(f"      Сквад '{NEW_SQUAD_NAME}' уже есть — добавляю инбаунды в него.")
        sq = api("GET", "/api/internal-squads", fatal=False)
        merged_ok = False
        if "__error__" not in sq:
            b = sq.get("response", sq)
            squads = b.get("internalSquads") if isinstance(b, dict) else b
            for s in (squads or []):
                if s.get("name") != NEW_SQUAD_NAME: continue
                cur = [ib["uuid"] if isinstance(ib, dict) else ib for ib in (s.get("inbounds") or [])]
                merged = list(dict.fromkeys(cur + active_uuids))
                pl = {"uuid": s["uuid"], "name": s.get("name"), "inbounds": merged}
                rr = api("PATCH", f"/api/internal-squads/{s['uuid']}", pl, fatal=False)
                if "__error__" not in rr: merged_ok = True; elog(f"      Обновлён '{NEW_SQUAD_NAME}'.")
                else: elog(f"      [WARN] {rr['__error__']}")
        if not merged_ok:
            elog("      [WARN] Не удалось до-мержить — проверь сквад в UI.")
    else:
        elog(f"      [WARN] Не создал сквад '{NEW_SQUAD_NAME}': {r['__error__']}")
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
json.dump(out, open(os.environ["RW_RESULT_FILE"], "w"))
print(json.dumps(out))
DEPLOYEOF

TAG_SUFFIX="$(echo "$NODE_DOMAIN" | tr -cd 'A-Za-z0-9' | cut -c1-12)-$(openssl rand -hex 3)"
NODE_ADDRESS="${PUBLIC_IP:-$NODE_DOMAIN}"

log "Создаю профиль, ноду и хосты в панели..."
env RW_RESULT_FILE="$WORK_DIR/result.json" RW_CDN_HOST_NAME="$CDN_HOST_NAME" \
  RW_NODE_NAME="$NODE_NAME" RW_NODE_DOMAIN="$NODE_DOMAIN" RW_NODE_ADDRESS="$NODE_ADDRESS" \
  RW_NODE_PORT="$NODE_PORT" RW_HOST_PREFIX="$HOST_PREFIX" RW_TAG_SUFFIX="$TAG_SUFFIX" \
  RW_SNI_DONOR="$SNI_DONOR" RW_ENABLE_CDN="$ENABLE_CDN" RW_ENABLE_BRIDGE="$ENABLE_BRIDGE" \
  RW_MIN_CLIENT_VER="$MIN_CLIENT_VER" \
  RW_SQUAD_MODE="$SQUAD_MODE" RW_SQUAD_UUIDS="$SQUAD_UUIDS" RW_NEW_SQUAD_NAME="$NEW_SQUAD_NAME" \
  RW_CDN_PUBLIC_DOMAIN="$CDN_PUBLIC_DOMAIN" RW_CDN_PATH="$CDN_PATH" \
  RW_PORT_REALITY_GRPC="$PORT_REALITY_GRPC" \
  RW_PORT_REALITY_XHTTP="$PORT_REALITY_XHTTP" RW_PORT_HY2="$PORT_HY2" \
  RW_PORT_CDN_LOCAL="$PORT_CDN_LOCAL" RW_PORT_BRIDGE="$PORT_BRIDGE" \
  RW_SID_GRPC="$(openssl rand -hex 8)" \
  RW_SID_XHTTP="$(openssl rand -hex 8)" RW_XHTTP_PATH="/$(openssl rand -hex 8)/" \
  python3 "$WORK_DIR/deploy.py" || die "Провижининг в панели не прошёл (см. ошибку выше)."

NODE_UUID=$(python3 -c "import json;print(json.load(open('$WORK_DIR/result.json'))['nodeUuid'])")
PROFILE_UUID=$(python3 -c "import json;print(json.load(open('$WORK_DIR/result.json'))['profileUuid'])")
SECRET_KEY=$(python3 -c "import json;print(json.load(open('$WORK_DIR/result.json'))['secretKey'])")

# SECRET_KEY (общий ключ панели из /api/keygen) мог не прийти — попросим из UI.
if [[ -z "$SECRET_KEY" ]]; then
  warn "Панель не отдала ключ через /api/keygen (зависит от версии)."
  echo "Возьми его в панели: любая нода -> 'Copy docker-compose.yml' (значение SECRET_KEY),"
  echo "либо страница генерации ключа. Он одинаков для всех нод этой панели."
  read -rp "SECRET_KEY: " SECRET_KEY
  SECRET_KEY="$(echo "$SECRET_KEY" | tr -d '[:space:]\"')"
  [[ -n "$SECRET_KEY" ]] || die "Без SECRET_KEY нода не подключится."
fi

# ---------------------------------------------------------------------------
# docker-compose.yml ноды + запуск
# ---------------------------------------------------------------------------
log "Пишу docker-compose.yml ноды и поднимаю контейнер..."
cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=$NODE_PORT
SECRET_KEY=$SECRET_KEY
EOF
chmod 600 "$NODE_DIR/.env"
# Xray НЕ монтируем (см. выше) — только сертификаты для Hysteria2/TLS-инбаундов.
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
EOF
( cd "$NODE_DIR" && docker compose up -d ) || warn "docker compose up вернул ошибку — проверь: docker logs remnanode"

# ---------------------------------------------------------------------------
# Боевой Nginx (заглушка + камуфляж 8443 + origin CDN)
# ---------------------------------------------------------------------------
log "Пишу боевой конфиг Nginx..."
# nginx >= 1.25.1: "listen ... http2" устарел, нужен "http2 on;".
NGX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [[ -n "$NGX_VER" ]] && [[ "$(printf '%s\n1.25.1\n' "$NGX_VER" | sort -V | head -1)" == "1.25.1" ]]; then
  NGX_H2_LISTEN=""; NGX_H2_DIRECTIVE="    http2 on;"
else
  NGX_H2_LISTEN=" http2"; NGX_H2_DIRECTIVE=""
fi
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
    listen 443 ssl${NGX_H2_LISTEN} default_server;
    listen [::]:443 ssl${NGX_H2_LISTEN} default_server;
${NGX_H2_DIRECTIVE}
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
FW_TCP="$PORT_REALITY_GRPC, $PORT_REALITY_XHTTP, 80, 443, 8443"
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
# Повторный прогон: удаляем старые правила rw-node*, чтобы порты/IP обновились.
for h in \$(nft -a list chain inet filter input 2>/dev/null | grep 'comment "rw-node' | grep -oE 'handle [0-9]+' | awk '{print \$2}'); do
  nft delete rule inet filter input handle "\$h" 2>/dev/null || true
done
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
  for p in $PORT_REALITY_GRPC $PORT_REALITY_XHTTP 80 443 8443; do ufw allow "$p"/tcp >/dev/null 2>&1 || true; done
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
# Ждём, пока панель увидит ноду (после того как открыли фаервол)
# ---------------------------------------------------------------------------
log "Жду подключения ноды к панели (до 90 с)..."
cat > "$WORK_DIR/wait.py" <<'WAITEOF'
import json, os, sys, time, urllib.request
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
UUID = sys.argv[1]
deadline = time.time() + 90
last = ""
while time.time() < deadline:
    try:
        req = urllib.request.Request(f"{PANEL}/api/nodes/{UUID}")
        req.add_header("Authorization", "Bearer " + TOK)
        with urllib.request.urlopen(req, timeout=15) as r:
            n = json.loads(r.read().decode()).get("response", {})
        if n.get("isConnected"):
            print("online"); sys.exit(0)
        last = n.get("lastStatusMessage") or ""
    except Exception as e:
        last = str(e)
    time.sleep(5)
print(last or "timeout"); sys.exit(1)
WAITEOF
if NODE_STATUS=$(python3 "$WORK_DIR/wait.py" "$NODE_UUID" 2>/dev/null); then
  NODE_ONLINE=true; log "Нода подключена к панели."
else
  NODE_ONLINE=false
  warn "Панель пока не видит ноду: ${NODE_STATUS:-нет ответа}"
  warn "Проверь: docker logs remnanode --tail 50, NODE_PORT $NODE_PORT открыт для ${PANEL_IP:-панели}, SECRET_KEY верный."
fi

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
[[ -n "$HOST_PREFIX" ]] && echo "Хосты:   \"$HOST_PREFIX ...\" (подходят под шаблон автовыбора)"
echo ""
echo "Инбаунды:"
echo "  Reality gRPC          TCP  $PORT_REALITY_GRPC"
echo "  Reality XHTTP         TCP  $PORT_REALITY_XHTTP  (нужен свежий клиент, напр. Happ)"
echo "  Hysteria2             UDP  $PORT_HY2  (проверь, что UDP $PORT_HY2 открыт у провайдера)"
[[ "$ENABLE_CDN" == "true" ]] && echo "  CDN XHTTP             Yandex CDN -> Nginx -> 127.0.0.1:$PORT_CDN_LOCAL"
[[ "$ENABLE_BRIDGE" == "true" ]] && echo "  BRIDGE_IN             TCP  $PORT_BRIDGE  (межнодовый; в подписку не идёт)"
echo ""
if [[ "$NODE_ONLINE" == "true" ]]; then
  echo "Статус:  нода ONLINE в панели"
else
  echo "Статус:  панель пока не видит ноду — docker logs remnanode --tail 50"
fi
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
