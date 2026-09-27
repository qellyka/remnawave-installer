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
#   - опционально выпускает Cloudflare WARP и выводит через него трафик
#     (весь или только выбранные сервисы), проверяя, что страна WARP-IP
#     совпадает со страной сервера;
#   - каскад: выходная нода получает мост BRIDGE_IN (VLESS+Reality+XHTTP) и
#     сервисного пользователя; входная нода (роль "entry") подключается к
#     выбранному выходу, RU-сайты отпускает напрямую, остальное шлёт в выход;
#   - маскировка Reality: self-steal (SNI = свой домен, Reality на 443,
#     сайт-заглушка за ним через PROXY protocol) или чужой SNI-донор;
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
# UTF-8 локаль нужна, чтобы ${#var} считал символы (выравнивание в выводе).
if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8; fi

# ============================================================================
#  UI: цвета, шаги, спиннер. Без TTY (или NO_COLOR=1) — простой вывод.
# ============================================================================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  UI_TTY=1
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[38;5;203m'; C_GRN=$'\033[38;5;114m'; C_YEL=$'\033[38;5;221m'
  C_BLU=$'\033[38;5;111m'; C_MAG=$'\033[38;5;177m'; C_CYN=$'\033[38;5;80m'
else
  UI_TTY=0; C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYN=""
fi
LOG_FILE="/var/log/remnanode-deploy.log"
STEP_N=0; STEP_TOTAL=11
Q="  ${C_MAG}?${C_RST} "          # префикс вопросов

log()  { printf '  %s›%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s⚠ %s%s\n' "$C_YEL" "$*" "$C_RST"; }
die()  {
  printf '\r\033[K\n  %s%s✗ %s%s\n' "$C_RED" "$C_B" "$*" "$C_RST" >&2
  [[ -s "$LOG_FILE" ]] && printf '  %sподробности: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RST" >&2
  exit 1
}
hr()   { printf '  %s┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄%s\n' "$C_DIM" "$C_RST"; }
kv()   {  # ключ-значение с выравниванием по символам (не байтам — кириллица)
  local n=${#1} pad
  pad=$(( n < 14 ? 14 - n : 1 ))
  printf '  %s│%s %s%s%*s%s %s\n' "$C_DIM" "$C_RST" "$C_DIM" "$1" "$pad" "" "$C_RST" "$2"
}

step() {
  STEP_N=$((STEP_N + 1))
  printf '\n  %s╭─%s %s%s%02d/%02d%s %s%s%s\n' "$C_MAG" "$C_RST" "$C_B" "$C_MAG" \
    "$STEP_N" "$STEP_TOTAL" "$C_RST" "$C_B" "$1" "$C_RST"
  printf '  %s╰─%s %s' "$C_MAG" "$C_RST" "$C_DIM"
  local i filled=$(( STEP_N * 30 / STEP_TOTAL ))
  for ((i = 0; i < 30; i++)); do (( i < filled )) && printf '━' || printf '┄'; done
  printf '%s\n' "$C_RST"
}

# spin "сообщение" команда [аргументы...] — вывод команды уходит в $LOG_FILE
spin() {
  local msg="$1"; shift
  local t0=$SECONDS rc=0
  printf '\n### %s — %s\n' "$(date '+%F %T')" "$msg" >> "$LOG_FILE"
  if [[ $UI_TTY -eq 0 ]]; then
    log "$msg..."
    "$@" >> "$LOG_FILE" 2>&1 || rc=$?
  else
    "$@" >> "$LOG_FILE" 2>&1 &
    local pid=$! i=0
    local -a fr=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    printf '\033[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s %s%ds%s\033[K' "$C_CYN" "${fr[i % 10]}" "$C_RST" "$msg" "$C_DIM" $((SECONDS - t0)) "$C_RST"
      i=$((i + 1)); sleep 0.08
    done
    wait "$pid" || rc=$?
    printf '\r\033[K\033[?25h'
  fi
  if [[ $rc -eq 0 ]]; then
    printf '  %s✓%s %s %s%ds%s\n' "$C_GRN" "$C_RST" "$msg" "$C_DIM" $((SECONDS - t0)) "$C_RST"
  else
    printf '  %s✗%s %s %s(код %d)%s\n' "$C_RED" "$C_RST" "$msg" "$C_DIM" "$rc" "$C_RST"
    tail -n 6 "$LOG_FILE" | sed "s/^/    ${C_DIM}│ /; s/\$/${C_RST}/"
  fi
  return $rc
}

banner() {
  local -a L=(
    "┏━┓┏━╸┏┳┓┏┓╻┏━┓┏┓╻┏━┓╺┳┓┏━╸"
    "┣┳┛┣╸ ┃┃┃┃┗┫┣━┫┃┗┫┃ ┃ ┃┃┣╸ "
    "╹┗╸┗━╸╹ ╹╹ ╹╹ ╹╹ ╹┗━┛╺┻┛┗━╸"
  )
  local -a C=("$C_MAG" "$C_BLU" "$C_CYN")
  printf '\n'
  for i in 0 1 2; do
    printf '   %s%s%s%s\n' "$C_B" "${C[$i]}" "${L[$i]}" "$C_RST"
    [[ $UI_TTY -eq 1 ]] && sleep 0.06
  done
  printf '   %sустановка ноды Remnawave с нуля · by qellyka%s\n' "$C_DIM" "$C_RST"
  printf '   %sобычная нода · WARP · каскад · Yandex CDN%s\n\n' "$C_DIM" "$C_RST"
}

[[ $EUID -eq 0 ]] || die "Запускай от root (sudo)."

# Все временные файлы (в т.ч. с токеном и SECRET_KEY) — в приватной папке,
# которая удаляется при любом выходе.
umask 022
WORK_DIR="$(mktemp -d /tmp/rw-deploy.XXXXXX)"
chmod 700 "$WORK_DIR"
trap 'printf "\033[?25h"; rm -rf "$WORK_DIR"' EXIT
trap 'kill $(jobs -p) 2>/dev/null; printf "\033[?25h\n"; exit 130' INT
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="$WORK_DIR/deploy.log"
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
PORT_SS_LOCAL=9443     # self-steal: nginx слушает 127.0.0.1 (PROXY protocol) за Reality
NODE_PORT=2222         # внутренний API ноды <-> панель

# Занят ли apt/dpkg — по реальным блокировкам файлов, а не по именам процессов.
# (pgrep -f unattended-upgr ловил демон unattended-upgrade-shutdown, который
# на Ubuntu/Debian висит ВСЕГДА — и скрипт ждал вечно.) dpkg/apt ставят
# fcntl-блокировки; они видны в /proc/locks как major:minor:inode.
lock_held() {
  local f="$1" ino
  [[ -e "$f" ]] || return 1
  ino=$(stat -c %i "$f" 2>/dev/null) || return 1
  grep -qE "[0-9a-f]+:[0-9a-f]+:${ino} " /proc/locks 2>/dev/null
}
apt_busy() {
  lock_held /var/lib/dpkg/lock-frontend || lock_held /var/lib/dpkg/lock \
    || lock_held /var/lib/apt/lists/lock || lock_held /var/cache/apt/archives/lock
}
wait_for_apt_lock() {
  local waited=0 max_wait=900
  while apt_busy; do
    [[ $waited -eq 0 ]] && warn "apt/dpkg занят (на свежем сервере это unattended-upgrades). Жду..."
    sleep 5; waited=$((waited + 5))
    [[ $waited -ge $max_wait ]] && die "apt/dpkg занят больше 15 минут — проверь: ps aux | grep -i apt"
  done
  [[ $waited -gt 0 ]] && log "Дождался освобождения apt/dpkg (${waited}s)."
  return 0
}

is_ip() {  # IPv4 или IPv6 (грубая, но достаточная проверка)
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:.]*$ ]]
}

read_clean() {  # $1 prompt, $2 varname, $3 charset — чистит артефакты вставки
  local prompt="$1" __var="$2" charset="$3" value
  read -rp "${Q}$prompt" value
  value="$(echo "$value" | tr -cd "$charset")"
  printf -v "$__var" '%s' "$value"
}

banner
step "Параметры установки"

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
  read -rp "${Q}Нашёл сохранённый API-токен ($TOKEN_FILE). Использовать его? [Y/n]: " USE_SAVED
  if [[ ! "$USE_SAVED" =~ ^[Nn]$ ]]; then
    API_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    AUTH_CHOICE="saved"
  fi
fi
if [[ -z "$AUTH_CHOICE" ]]; then
echo "  Авторизация в панели:"
echo "    1) Готовый API-токен — СОЗДАЙ его в UI: Settings -> API Tokens (рекомендуется)"
echo "    2) Логин + пароль (скрипт попробует выпустить токен сам — многие панели"
echo "       это ЗАПРЕЩАЮТ и вернут 403 'must create own API-token')"
read -rp "${Q}Введите номер [1-2]: " AUTH_CHOICE
if [[ "$AUTH_CHOICE" == "2" ]]; then
  read -rp "${Q}Логин администратора панели: " RW_LOGIN
  read -rsp "${Q}Пароль администратора: " RW_PASSWORD; echo
  [[ -n "$RW_LOGIN" && -n "$RW_PASSWORD" ]] || die "Логин и пароль обязательны"
else
  read -rp "${Q}API-токен: " API_TOKEN
  API_TOKEN="$(echo "$API_TOKEN" | tr -d '[:space:]')"
  [[ -n "$API_TOKEN" ]] || die "Токен пуст"
fi
fi

hr
echo "  Роль ноды:"
echo "    1) обычная / выходная — клиенты выходят в интернет с этого сервера"
echo "       (можно включить мост BRIDGE_IN, чтобы она была выходом каскада)"
echo "    2) входная нода каскада — клиенты подключаются сюда, RU-сайты идут"
echo "       напрямую, остальное пересылается на выбранную выходную ноду"
read -rp "${Q}Роль [1/2, Enter — 1]: " ROLE_ANS
NODE_ROLE="exit"; [[ "$ROLE_ANS" == "2" ]] && NODE_ROLE="entry"

read_clean "Имя ноды в панели (например DE-1): " NODE_NAME 'A-Za-z0-9 _.-'
[[ -n "$NODE_NAME" ]] || NODE_NAME="node-$(date +%s)"

hr
echo "  Домен этой ноды — на него сертификат, заглушка, origin CDN, SNI Hy2."
read_clean "Домен ноды (например de1.example.com): " NODE_DOMAIN 'A-Za-z0-9.-'
[[ -n "$NODE_DOMAIN" ]] || die "Домен обязателен"

hr
ENABLE_BRIDGE=false
BRIDGE_PEERS=""
if [[ "$NODE_ROLE" == "exit" ]]; then
  echo "  Мост BRIDGE_IN — делает эту ноду ВЫХОДОМ каскада: к ней будут"
  echo "  подключаться входные ноды (VLESS+Reality+XHTTP, порт $PORT_BRIDGE)."
  echo "  В подписку он не идёт, доступ — только у сервисного пользователя."
  read -rp "${Q}Включить BRIDGE_IN? [y/N]: " BRIDGE_ANS
  if [[ "$BRIDGE_ANS" =~ ^[Yy]$ ]]; then
    ENABLE_BRIDGE=true
    echo "  IP входных нод, которым разрешить порт $PORT_BRIDGE (через пробел)."
    echo "  Enter — открыть всем (мост всё равно закрыт Reality + UUID)."
    while true; do
      read -rp "${Q}IP входных нод: " BRIDGE_PEERS
      _bad=""; for ip in $BRIDGE_PEERS; do is_ip "$ip" || _bad="$ip"; done
      [[ -z "$_bad" ]] && break
      warn "«$_bad» — не IP-адрес. Введи IP через пробел или Enter."
    done
  fi
fi

hr
echo "  Yandex CDN — вход для клиентов через CDN (Enter — без CDN)."
if [[ "$NODE_ROLE" == "entry" ]]; then
  echo "  ${C_CYN}Каскад:${C_RST} CDN будет указывать на ЭТОТ входной сервер:"
  echo "  ${C_DIM}клиент → Yandex CDN → $NODE_DOMAIN (вход) → мост → выход${C_RST}"
elif [[ "$ENABLE_BRIDGE" == "true" ]]; then
  echo "  ${C_YEL}Это выход каскада.${C_RST} CDN здесь нужен, только если клиенты ходят на"
  echo "  эту ноду НАПРЯМУЮ. Для каскада CDN ставь на входную ноду (роль 2)."
fi
read_clean "Публичный домен CDN (например cdn.example.com): " CDN_PUBLIC_DOMAIN 'A-Za-z0-9.-'
ENABLE_CDN=false; [[ -n "$CDN_PUBLIC_DOMAIN" ]] && ENABLE_CDN=true

hr
echo "  Cloudflare WARP — выход в интернет с IP Cloudflare вместо IP сервера."
echo "    0) не использовать"
echo "    1) весь трафик через WARP"
echo "    2) только выбранные сервисы (ИИ, стриминг) — остальное напрямую"
WARP_ANS=0
if [[ "$NODE_ROLE" == "exit" ]]; then
  read -rp "${Q}WARP [0/1/2, Enter — 0]: " WARP_ANS
else
  echo "  (для входной ноды WARP не нужен — он включается на выходной)"
fi
case "$WARP_ANS" in
  1) WARP_MODE="all" ;;
  2) WARP_MODE="selected" ;;
  *) WARP_MODE="off" ;;
esac
WARP_DOMAINS_DEFAULT="openai.com,chatgpt.com,oaistatic.com,oaiusercontent.com,anthropic.com,claude.ai,claude.com,gemini.google.com,aistudio.google.com,generativelanguage.googleapis.com,notebooklm.google.com,perplexity.ai,grok.com,x.ai,netflix.com,nflxvideo.net,spotify.com"
WARP_DOMAINS=""
WARP_LICENSE=""
if [[ "$WARP_MODE" != "off" ]]; then
  echo "  WARP+ снимает скоростной лимит бесплатного WARP. Ключ: приложение 1.1.1.1 -> Account -> Key."
  read_clean "WARP+ license key (Enter — бесплатный WARP): " WARP_LICENSE 'A-Za-z0-9-'
fi
if [[ "$WARP_MODE" == "selected" ]]; then
  echo "  Домены через WARP (с поддоменами). По умолчанию: ИИ-сервисы, Netflix, Spotify."
  read -rp "${Q}Свой список через запятую (Enter — по умолчанию): " WARP_DOMAINS
  WARP_DOMAINS="$(echo "${WARP_DOMAINS:-$WARP_DOMAINS_DEFAULT}" | tr -d '[:space:]')"
fi

hr
echo "  Маскировка Reality:"
echo "    1) ${C_B}self-steal${C_RST} — SNI = домен этой ноды, Reality XHTTP на 443, а за ним"
echo "       настоящий сайт-заглушка с сертификатом Let's Encrypt. SNI совпадает"
echo "       с IP сервера — нет расхождения, которое ловит ТСПУ (рекомендуется)"
echo "    2) чужой SNI-донор — SNI крупного сайта (google/ya.ru...), как было"
_ss_def=1
if [[ "$NODE_ROLE" == "entry" ]]; then
  _ss_def=2
  echo "  ${C_YEL}Входная нода:${C_RST} при «белых списках» на мобильном свой домен может не"
  echo "  пройти фильтр по SNI — для входа в РФ надёжнее донор из белого списка (2)."
fi
read -rp "${Q}Маскировка [1/2, Enter — $_ss_def]: " SS_ANS
SS_ANS="${SS_ANS:-$_ss_def}"
SELF_STEAL=false
if [[ "$SS_ANS" == "1" ]]; then
  SELF_STEAL=true
  PORT_REALITY_XHTTP=443
fi

hr
echo "  Код страны ноды (2 буквы, например DE, PL, FI) — из него соберу имена"
echo "  хостов вида \"🇩🇪 DE | Reality gRPC\" — такой формат подхватывает шаблон автовыбора."
# Флаг из кода страны без python (на чистом сервере его ещё может не быть):
# региональные индикаторы U+1F1E6.. = байты F0 9F 87 A6+n.
flag_of() {
  local cc="$1" out="" i c n
  [[ "$cc" =~ ^[A-Z]{2}$ ]] || return 0
  for ((i = 0; i < 2; i++)); do
    c="${cc:i:1}"; n=$(( $(printf '%d' "'$c") - 65 ))
    out+=$(printf "\\xF0\\x9F\\x87\\x$(printf '%X' $((0xA6 + n)))")
  done
  printf '%s' "$out"
}
COUNTRY_CODE=""
HOST_PREFIX=""
if [[ "$NODE_ROLE" == "entry" ]]; then
  echo "  (для входной ноды префикс соберу сам: флаг входа + флаг выхода + код выхода)"
else
  read_clean "Код страны (Enter — без префикса): " COUNTRY_CODE 'A-Za-z'
  COUNTRY_CODE="$(echo "$COUNTRY_CODE" | tr '[:lower:]' '[:upper:]' | cut -c1-2)"
fi
if [[ "$NODE_ROLE" == "entry" ]]; then
  :
elif [[ ${#COUNTRY_CODE} -eq 2 ]]; then
  FLAG="$(flag_of "$COUNTRY_CODE")"
  HOST_PREFIX="${FLAG:+$FLAG }$COUNTRY_CODE |"
  log "Префикс хостов: \"$HOST_PREFIX\""
else
  read -rp "${Q}Свой префикс к именам хостов (Enter — без префикса): " HOST_PREFIX
fi
CDN_HOST_NAME="LTE"
if [[ "$ENABLE_CDN" == "true" ]]; then
  read -rp "${Q}Имя CDN-хоста [LTE]: " _cdnn
  CDN_HOST_NAME="${_cdnn:-LTE}"
fi

# IP панели (для правила файрвола на NODE_PORT) — резолвим хост панели.
PANEL_HOST="$(echo "$PANEL_URL" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##')"
PANEL_IP=""

hr
printf '  %s╭─ Что ставим%s\n' "$C_MAG" "$C_RST"
case "$NODE_ROLE:$ENABLE_BRIDGE" in
  entry:*)   kv "Роль" "входная нода каскада (выход выберешь после авторизации)" ;;
  exit:true) kv "Роль" "обычная нода + выход каскада (мост :$PORT_BRIDGE)" ;;
  *)         kv "Роль" "обычная нода" ;;
esac
kv "Нода" "$NODE_NAME · $NODE_DOMAIN"
kv "Маскировка" "$([[ "$SELF_STEAL" == "true" ]] && echo "self-steal (Reality XHTTP на 443)" || echo "SNI-донор")"
kv "CDN" "$([[ "$ENABLE_CDN" == "true" ]] && echo "$CDN_PUBLIC_DOMAIN" || echo "нет")"
kv "WARP" "$WARP_MODE"
[[ -n "$HOST_PREFIX" ]] && kv "Хосты" "$HOST_PREFIX …"
printf '  %s╰─%s\n' "$C_MAG" "$C_RST"
echo "  Проверь перед стартом:"
echo "    A-запись $NODE_DOMAIN -> IP этого сервера"
[[ "$ENABLE_CDN" == "true" ]] && echo "  $CDN_PUBLIC_DOMAIN — CNAME на Yandex CDN добавим ПОСЛЕ (инструкция в конце)"
read -rp "${Q}Enter, когда A-запись для $NODE_DOMAIN готова: "

step "Зависимости и Docker"
# ---------------------------------------------------------------------------
# Зависимости + Docker
# ---------------------------------------------------------------------------
wait_for_apt_lock
spin "Обновляю списки пакетов" apt-get update -q || true
wait_for_apt_lock
spin "Ставлю зависимости (nginx, certbot, python3...)" \
  apt-get install -y -q curl python3 openssl dnsutils nginx certbot ca-certificates unzip tar nftables iproute2 \
  || die "apt-get не смог поставить зависимости"

if ! command -v docker >/dev/null 2>&1; then
  spin "Ставлю Docker (get.docker.com)" bash -c 'curl -fsSL https://get.docker.com | sh' \
    || die "Не удалось поставить Docker"
  systemctl enable --now docker >/dev/null 2>&1 || true
else
  ok "Docker уже установлен."
fi
# Compose v2 (плагин). Если нет — ставим.
if ! docker compose version >/dev/null 2>&1; then
  warn "docker compose (v2) не найден — ставлю плагин..."
  wait_for_apt_lock
  spin "Ставлю docker-compose-plugin" apt-get install -y -q docker-compose-plugin || \
    warn "Не смог поставить docker-compose-plugin — если compose нет, поставь вручную."
fi

PUBLIC_IP=$(curl -s -4 --max-time 5 https://api.ipify.org || echo "")
RESOLVED=$(dig +short "$NODE_DOMAIN" A | tail -n1 || true)
if [[ -z "$RESOLVED" ]]; then
  warn "$NODE_DOMAIN пока не резолвится — certbot, скорее всего, не пройдёт."
elif [[ -n "$PUBLIC_IP" && "$RESOLVED" != "$PUBLIC_IP" ]]; then
  warn "$NODE_DOMAIN резолвится в $RESOLVED, а не в $PUBLIC_IP — certbot может не пройти."
  warn "Если домен в Cloudflare — выключи проксирование (серое облако): с оранжевым не заработают ни Reality, ни Hysteria2."
else
  ok "DNS в порядке: $NODE_DOMAIN -> $RESOLVED"
fi
# Let's Encrypt предпочитает IPv6: чужая AAAA-запись = провал выпуска.
RESOLVED6=$(dig +short "$NODE_DOMAIN" AAAA | grep ':' | tail -n1 || true)
if [[ -n "$RESOLVED6" ]] && ! ip -6 addr 2>/dev/null | grep -qi "${RESOLVED6%%/*}"; then
  warn "У $NODE_DOMAIN есть AAAA-запись $RESOLVED6, но это не адрес сервера — удали её, иначе certbot упадёт."
fi
# Ядро без IPv6 (ipv6.disable=1): слушать [::] нельзя — и nginx, и xray упадут.
HAS_V6=false; [[ -e /proc/net/if_inet6 ]] && HAS_V6=true
PANEL_IP=$(dig +short "$PANEL_HOST" A | tail -n1 || true)
# Если панель за Cloudflare/CDN, DNS отдаёт IP прокси, а не сервера панели —
# тогда правило на NODE_PORT заблокирует саму панель. Даём поправить.
echo "  IP сервера ПАНЕЛИ (с него панель ходит на NODE_PORT $NODE_PORT)."
echo "  Если панель за Cloudflare/CDN — DNS покажет не тот IP, впиши реальный."
while true; do
  read -rp "${Q}IP панели [${PANEL_IP:-не определён}] (Enter — принять, 'any' — открыть всем): " _pip
  _pip="$(echo "$_pip" | tr -d '[:space:]')"
  if [[ "$_pip" == "any" ]]; then PANEL_IP=""; break
  elif [[ -z "$_pip" ]]; then break
  elif is_ip "$_pip"; then PANEL_IP="$_pip"; break
  fi
  warn "«$_pip» — не IP-адрес."
done
[[ -z "$PANEL_IP" ]] || is_ip "$PANEL_IP" || PANEL_IP=""
if [[ -n "$PANEL_IP" ]]; then
  log "NODE_PORT $NODE_PORT будет открыт только для $PANEL_IP."
else
  warn "NODE_PORT $NODE_PORT будет открыт ВСЕМ — ограничь его позже."
fi

step "Авторизация в панели"
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
  ok "API-токен получен."
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
python3 "$WORK_DIR/check.py" >/dev/null \
  || die "Токен не работает (см. выше). Если это сохранённый токен — удали $TOKEN_FILE и запусти заново."
rm -f "$WORK_DIR/check.py"
ok "Токен рабочий."

# Сохраним токен для повторных прогонов (chmod 600).
( umask 077; printf '%s\n' "$API_TOKEN" > "$TOKEN_FILE" )

# Версия xray в образе ноды -> minClientVer (отсекает старые Reality-клиенты).
# Можно задать руками: MIN_CLIENT_VER=26.7.28 bash remnanode-deploy.sh
# (MIN_CLIENT_VER=none — не ограничивать).
spin "Скачиваю образ ноды $NODE_IMAGE" docker pull "$NODE_IMAGE" \
  || warn "docker pull не прошёл — попробую с тем, что есть."
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


step "Сквады и каскад"
# ---------------------------------------------------------------------------
# Повторный запуск на том же сервере: нода с этим адресом уже есть в панели
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/existing.py" <<'EXISTEOF'
import json, os, sys, urllib.request, urllib.error
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
def api(method, path):
    req = urllib.request.Request(PANEL + path, method=method)
    req.add_header("Authorization", "Bearer " + TOK)
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode() or "{}"); return d.get("response", d)
mode, addrs = sys.argv[1], [a for a in sys.argv[2:] if a]
nodes = api("GET", "/api/nodes"); nodes = nodes.get("nodes", nodes) if isinstance(nodes, dict) else nodes
hit = next((n for n in nodes or [] if n.get("address") in addrs), None)
if not hit: sys.exit(0)
prof = (hit.get("configProfile") or {}).get("activeConfigProfileUuid") or ""
if mode == "find":
    bridge = "0"
    if prof:
        try:
            cfg = api("GET", f"/api/config-profiles/{prof}").get("config") or {}
            bridge = "1" if any(i.get("tag", "").startswith("bridge-in-") for i in cfg.get("inbounds", [])) else "0"
        except Exception: pass
    print(f"{hit['uuid']}|{hit.get('name')}|{prof}|{bridge}"); sys.exit(0)
# mode == "delete": хосты старого профиля -> нода -> профиль
hosts = api("GET", "/api/hosts"); hosts = hosts.get("hosts", hosts) if isinstance(hosts, dict) else hosts
for h in hosts or []:
    if ((h.get("inbound") or {}).get("configProfileUuid")) == prof:
        try: api("DELETE", f"/api/hosts/{h['uuid']}")
        except Exception as e: print(f"хост {h.get('remark')}: {e}", file=sys.stderr)
# Служебные сущности моста старого выхода: пользователь и сквад bridge-<suffix>.
if prof:
    try:
        cfg = api("GET", f"/api/config-profiles/{prof}").get("config") or {}
        for ib in cfg.get("inbounds", []):
            t = ib.get("tag", "")
            if not t.startswith("bridge-in-"): continue
            bname = "bridge-" + t[len("bridge-in-"):]
            try:
                u = api("GET", f"/api/users/by-username/{bname[:36]}")
                api("DELETE", f"/api/users/{u['uuid']}")
            except Exception: pass
            sq = api("GET", "/api/internal-squads")
            sq = sq.get("internalSquads", sq) if isinstance(sq, dict) else sq
            for q in sq or []:
                if q.get("name") == bname[:30]:
                    try: api("DELETE", f"/api/internal-squads/{q['uuid']}")
                    except Exception: pass
    except Exception as e:
        print(f"служебные сущности моста: {e}", file=sys.stderr)
api("DELETE", f"/api/nodes/{hit['uuid']}")
if prof:
    try: api("DELETE", f"/api/config-profiles/{prof}")
    except Exception as e: print(f"профиль {prof}: {e}", file=sys.stderr)
EXISTEOF
OLD_NODE=$(python3 "$WORK_DIR/existing.py" find "$PUBLIC_IP" "$NODE_DOMAIN" 2>/dev/null || true)
if [[ -n "$OLD_NODE" ]]; then
  IFS='|' read -r _on_uuid _on_name _on_prof _on_bridge <<< "$OLD_NODE"
  warn "В панели уже есть нода «$_on_name» с адресом этого сервера (повторная установка?)."
  [[ "$_on_bridge" == "1" ]] && warn "Это выход каскада: входные ноды, смотрящие на неё, придётся переустановить."
  echo "  Пересоздание удалит старую ноду, её профиль, хосты и служебного юзера моста."
  echo "  Обычные пользователи и их сквады не трогаются."
  read -rp "${Q}Удалить старую ноду и поставить заново? [y/N]: " _del
  [[ "$_del" =~ ^[Yy]$ ]] || die "Отменено: нода с этим адресом уже есть в панели."
  python3 "$WORK_DIR/existing.py" delete "$PUBLIC_IP" "$NODE_DOMAIN" || die "Не смог удалить старую ноду — удали её в панели вручную."
  ok "Старая нода «$_on_name» удалена из панели."
fi

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
    if str(s.get("name", "")).startswith("bridge-"): continue  # служебные сквады мостов
    n = len(s.get("inbounds") or [])
    print(f"{s['uuid']}|{s.get('name','?')}|{n}")
SQEOF

SQUAD_MODE="ALL"; SQUAD_UUIDS=""; NEW_SQUAD_NAME=""
SQUADS_LIST=$(python3 "$WORK_DIR/squads.py" 2>/dev/null || true)
rm -f "$WORK_DIR/squads.py"
hr
echo "  Internal Squads — в какие добавить инбаунды этой ноды?"
if [[ -n "$SQUADS_LIST" ]]; then
  echo "  Существующие сквады:"
  i=1
  declare -a SQ_UUID_ARR=()
  while IFS='|' read -r uuid name cnt; do
    [[ -z "$uuid" ]] && continue
    printf "  %s) %s  (инбаундов: %s)\n" "$i" "$name" "$cnt"
    SQ_UUID_ARR[$i]="$uuid"
    i=$((i+1))
  done <<< "$SQUADS_LIST"
else
  echo "  (существующих сквадов нет или список не получен)"
fi
echo ""
echo "    a) во ВСЕ существующие сквады"
echo "    n) создать НОВЫЙ сквад"
echo "    s) пропустить (никуда не добавлять)"
echo "    или введи номера через пробел (например: 1 3)"
read -rp "${Q}Выбор [a/n/s/номера]: " SQ_CHOICE
case "$SQ_CHOICE" in
  a|A|"") SQUAD_MODE="ALL" ;;
  s|S) SQUAD_MODE="NONE" ;;
  n|N)
    SQUAD_MODE="NEW"
    read -rp "${Q}Имя нового сквада: " NEW_SQUAD_NAME
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
# Входная нода: выбор выходной ноды (у которой есть мост bridge-in-*)
# ---------------------------------------------------------------------------
EXIT_FILE=""
ENTRY_CC=""
ENTRY_RU_DIRECT=false
if [[ "$NODE_ROLE" == "entry" ]]; then
  cat > "$WORK_DIR/exits.py" <<'EXITSEOF'
import base64, json, os, subprocess, sys, urllib.request, urllib.error
PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOK = os.environ["RW_API_TOKEN"]
def api(path):
    req = urllib.request.Request(PANEL + path)
    req.add_header("Authorization", "Bearer " + TOK)
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode()); return d.get("response", d)
def pub_from_priv(p):
    # Reality-ключи Xray — base64url без паддинга; публичный считаем openssl'ом.
    raw = base64.urlsafe_b64decode(p + "=" * (-len(p) % 4))
    der = bytes.fromhex("302e020100300506032b656e04220420") + raw
    out = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                         input=der, capture_output=True, check=True).stdout
    return base64.urlsafe_b64encode(out[-32:]).decode().rstrip("=")
profs = api("/api/config-profiles")
profs = profs.get("configProfiles", profs) if isinstance(profs, dict) else profs
nodes = api("/api/nodes")
nodes = nodes.get("nodes", nodes) if isinstance(nodes, dict) else nodes
res = []
for p in profs or []:
    full = api(f"/api/config-profiles/{p['uuid']}")
    cfg = full.get("config") or {}
    for ib in cfg.get("inbounds", []):
        tag = ib.get("tag", "")
        if not tag.startswith("bridge-in-"): continue
        ss = ib.get("streamSettings", {})
        if ss.get("security") != "reality":
            print(f"пропускаю {tag}: старый мост без Reality — переустанови выход", file=sys.stderr)
            continue
        rs = ss.get("realitySettings", {}); xs = ss.get("xhttpSettings", {})
        node = next((n for n in nodes or []
                     if (n.get("configProfile") or {}).get("activeConfigProfileUuid") == p["uuid"]), None)
        if not node: continue
        user = f"bridge-{tag[len('bridge-in-'):]}"[:36]
        try:
            u = api(f"/api/users/by-username/{user}")
        except urllib.error.HTTPError:
            print(f"пропускаю {tag}: нет сервисного пользователя {user}", file=sys.stderr); continue
        cc = (node.get("countryCode") or "").upper()
        res.append({"node": node.get("name"), "country": "" if cc == "XX" else cc,
                    "address": node.get("address"), "port": ib.get("port"),
                    "uuid": u.get("vlessUuid"), "sni": (rs.get("serverNames") or [""])[0],
                    "shortId": (rs.get("shortIds") or [""])[0],
                    "publicKey": pub_from_priv(rs["privateKey"]),
                    "path": xs.get("path", "/"), "tag": tag})
json.dump(res, open(sys.argv[1], "w"))
for i, e in enumerate(res, 1):
    print(f"{i}|{e['node']}|{e['country'] or '??'}|{e['address']}:{e['port']}")
EXITSEOF
  EXITS_LIST=$(python3 "$WORK_DIR/exits.py" "$WORK_DIR/exits.json") \
    || die "Не смог получить список выходных нод из панели."
  [[ -n "$EXITS_LIST" ]] || die "В панели нет выходных нод с мостом. Сначала поставь выход (роль 1 + BRIDGE_IN)."
  hr
  echo "  Выходные ноды с мостом:"
  while IFS='|' read -r n name cc addr; do
    printf "  %s) %s [%s] %s\n" "$n" "$name" "$cc" "$addr"
  done <<< "$EXITS_LIST"
  EXITS_N=$(grep -c . <<< "$EXITS_LIST")
  while true; do
    read -rp "${Q}Номер выходной ноды [1]: " EXIT_NUM
    EXIT_NUM="${EXIT_NUM:-1}"
    [[ "$EXIT_NUM" =~ ^[0-9]+$ ]] && (( EXIT_NUM >= 1 && EXIT_NUM <= EXITS_N )) && break
    warn "Введи число от 1 до $EXITS_N."
  done
  EXIT_FILE="$WORK_DIR/exit.json"
  python3 - "$WORK_DIR/exits.json" "$EXIT_NUM" "$EXIT_FILE" <<'PICKEOF' || die "Нет выходной ноды с таким номером."
import json, sys
lst = json.load(open(sys.argv[1])); i = int(sys.argv[2]) - 1
if not (0 <= i < len(lst)): sys.exit(1)
json.dump(lst[i], open(sys.argv[3], "w"))
PICKEOF
  EXIT_CC=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['country'])" "$EXIT_FILE")
  EXIT_NAME=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['node'])" "$EXIT_FILE")
  if [[ ! "$EXIT_CC" =~ ^[A-Z]{2}$ ]]; then
    read_clean "Код страны выхода $EXIT_NAME (2 буквы): " EXIT_CC 'A-Za-z'
    EXIT_CC="$(echo "$EXIT_CC" | tr '[:lower:]' '[:upper:]' | cut -c1-2)"
  fi
  ENTRY_CC=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace | grep '^loc=' | cut -d= -f2 || true)
  [[ "$ENTRY_CC" =~ ^[A-Z]{2}$ ]] || ENTRY_CC="RU"
  HOST_PREFIX="$(flag_of "$ENTRY_CC")$(flag_of "$EXIT_CC") $EXIT_CC |"
  # Механика каскада от страны не зависит; от неё зависят только две вещи:
  # отпускать ли RU-сайты напрямую и из какого списка брать SNI-донора.
  _def="n"; [[ "$ENTRY_CC" == "RU" ]] && _def="y"
  read -rp "${Q}Вход в $ENTRY_CC. Российские сайты отпускать напрямую с входа? [y/n, Enter — $_def]: " _rd
  _rd="${_rd:-$_def}"
  ENTRY_RU_DIRECT=false; [[ "$_rd" =~ ^[Yy]$ ]] && ENTRY_RU_DIRECT=true
  log "Выход: $EXIT_NAME ($EXIT_CC). Префикс хостов: \"$HOST_PREFIX\""
fi

step "Nginx, заглушка и сертификат"
# ---------------------------------------------------------------------------
# Nginx + сертификат + заглушка (сначала серт — он нужен профилю)
# ---------------------------------------------------------------------------
CDN_PATH="/uploadfiles/"
log "Настраиваю Nginx и выпускаю сертификат..."
mkdir -p /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled "$SSL_DIR" /var/www/certbot /var/www/html
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/hy2-ping.conf

if curl -fsSL "$DECOY_SITE_URL" -o /var/www/html/index.html 2>/dev/null && [[ -s /var/www/html/index.html ]]; then
  ok "Заглушка скачана с GitHub."
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
[[ "$HAS_V6" == "true" ]] || sed -i '/listen \[::\]/d' /etc/nginx/sites-available/default
nginx -t >/dev/null 2>&1 || die "Базовый конфиг Nginx не проходит — nginx -t покажет причину"
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx

if [[ ! -d "/etc/letsencrypt/live/$NODE_DOMAIN" ]]; then
  spin "Выпускаю сертификат Let's Encrypt для $NODE_DOMAIN" certbot certonly --webroot -w /var/www/certbot -d "$NODE_DOMAIN" \
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

step "Reality: выбор SNI-донора"
# ---------------------------------------------------------------------------
# SNI-донор Reality: проверяем кандидатов openssl'ом (TLS 1.3 + h2 + X25519)
# и берём самого быстрого. Без скачивания сканера и без сканирования подсетей
# (RealiTLScanner сам предупреждает, что сканы с VPS могут пометить сервер).
# ---------------------------------------------------------------------------
if [[ "$NODE_ROLE" == "entry" && "$ENTRY_CC" == "RU" ]]; then
  # Вход в РФ: SNI должен быть из «белого списка» мобильных операторов.
  SNI_CANDIDATES=("ya.ru" "vk.com" "www.ozon.ru" "www.wildberries.ru" "dzen.ru" "mail.ru")
else
  SNI_CANDIDATES=("www.google.com" "www.microsoft.com" "www.apple.com" "dl.google.com" "www.amazon.com" "swift.org")
fi
SNI_DONOR=""; _best_ms=999999
if [[ "$SELF_STEAL" == "true" ]]; then
  SNI_DONOR="$NODE_DOMAIN"
  SNI_CANDIDATES=()
  ok "Self-steal: SNI = $NODE_DOMAIN, Reality -> nginx 127.0.0.1:$PORT_SS_LOCAL (PROXY protocol)"
else
  log "Выбираю SNI-донора Reality..."
fi
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
if [[ "$SELF_STEAL" == "true" ]]; then
  :
elif [[ -z "$SNI_DONOR" ]]; then
  SNI_DONOR="www.google.com"; warn "Ни один кандидат не прошёл проверку — беру $SNI_DONOR."
else
  ok "SNI-донор: $SNI_DONOR"
fi

# ---------------------------------------------------------------------------
# Cloudflare WARP: регистрация + проверка страны выхода
# ---------------------------------------------------------------------------
# Аккаунт WARP регистрируется напрямую через API Cloudflare (как делают
# wgcf/warp-reg), ключ WireGuard генерим openssl'ом. WARP подключается к
# ноде как wireguard-outbound Xray — отдельные сервисы/интерфейсы не нужны.
# Страну выхода проверяем временным Xray из образа ноды: socks -> WARP ->
# cloudflare.com/cdn-cgi/trace. Перебираем эндпоинты, пока страна не совпадёт.
WARP_FILE="$NODE_DIR/warp.json"
WARP_OUTBOUND_FILE=""
WARP_EXIT_INFO=""
mkdir -p "$NODE_DIR"

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

# Применяет WARP+ ключ к уже зарегистрированному устройству (ключи и
# reserved не меняются, перерегистрация не нужна). Печатает тип аккаунта.
warp_apply_license() {
  WARP_LICENSE="$1" python3 - "$WARP_FILE" <<'WLICEOF'
import json, os, sys, urllib.error, urllib.request
w = json.load(open(sys.argv[1]))
def call(url, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json; charset=UTF-8")
    req.add_header("User-Agent", "okhttp/3.12.1")
    req.add_header("CF-Client-Version", "a-6.10-2158")
    req.add_header("Authorization", "Bearer " + w["token"])
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.loads(r.read().decode()); return d.get("result", d)
base = f'{w["api"]}/reg/{w["id"]}/account'
try:
    call(base, "PUT", {"license": os.environ["WARP_LICENSE"]})
except urllib.error.HTTPError as e:
    if e.code in (404, 405):
        call(base, "PATCH", {"license": os.environ["WARP_LICENSE"]})
    else:
        print(f"HTTP {e.code}: {e.read().decode(errors='replace')[:200]}", file=sys.stderr); sys.exit(1)
acc = call(base)
print(acc.get("account_type") or ("plus" if acc.get("warp_plus") else "free"))
WLICEOF
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

# $1 endpoint -> печатает "LOC IP" или ничего, если WARP не поднялся
warp_probe() {
  local ep="$1" port=$(( 30000 + RANDOM % 20000 )) tr
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
  docker rm -f rw-warp-test >/dev/null 2>&1 || true
  grep -qE '^warp=(on|plus)' <<<"$tr" || return 0
  echo "$(grep '^loc=' <<<"$tr" | cut -d= -f2) $(grep '^ip=' <<<"$tr" | cut -d= -f2)"
}

step "Cloudflare WARP"
[[ "$WARP_MODE" == "off" ]] && log "WARP выключен — пропускаю."
if [[ "$WARP_MODE" != "off" ]]; then
  log "Настраиваю Cloudflare WARP (режим: $WARP_MODE)..."
  if [[ -s "$WARP_FILE" ]]; then
    log "Нашёл сохранённый WARP-аккаунт ($WARP_FILE) — использую его."
  elif warp_register; then
    ok "WARP-аккаунт зарегистрирован."
  else
    warn "Не удалось зарегистрировать WARP — продолжаю без него."
    WARP_MODE="off"
  fi
  if [[ "$WARP_MODE" != "off" && -n "$WARP_LICENSE" ]]; then
    if _acct=$(warp_apply_license "$WARP_LICENSE"); then
      case "$_acct" in
        unlimited|plus) log "WARP+ активирован (тип аккаунта: $_acct)." ;;
        *) warn "Ключ принят, но аккаунт остался '$_acct' — лимит устройств исчерпан или ключ не подходит. Работаю на бесплатном WARP." ;;
      esac
    else
      warn "Не удалось применить WARP+ ключ — работаю на бесплатном WARP."
    fi
  fi
fi

if [[ "$WARP_MODE" != "off" ]]; then
  # Страна сервера глазами Cloudflare (без WARP) и ожидаемая страна.
  SERVER_LOC=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace | grep '^loc=' | cut -d= -f2 || true)
  WANT_LOC="${COUNTRY_CODE:-$SERVER_LOC}"
  log "Страна сервера: ${SERVER_LOC:-?}; нужна страна WARP-выхода: ${WANT_LOC:-любая}"
  WARP_ENDPOINTS=("engage.cloudflareclient.com:2408" "162.159.192.1:2408" "162.159.193.1:2408"
                  "162.159.195.1:2408" "188.114.96.1:2408" "188.114.97.1:2408"
                  "188.114.98.1:2408" "188.114.99.1:2408")
  WARP_EP=""; WARP_FALLBACK_EP=""; WARP_FALLBACK_INFO=""
  for ep in "${WARP_ENDPOINTS[@]}"; do
    res=$(warp_probe "$ep")
    if [[ -z "$res" ]]; then
      log "  $ep — WARP не поднялся"; continue
    fi
    loc="${res%% *}"; wip="${res#* }"
    log "  $ep — выход $loc ($wip)"
    [[ -z "$WARP_FALLBACK_EP" ]] && { WARP_FALLBACK_EP="$ep"; WARP_FALLBACK_INFO="$res"; }
    if [[ -z "$WANT_LOC" || "$loc" == "$WANT_LOC" ]]; then
      WARP_EP="$ep"; WARP_EXIT_INFO="$res"; break
    fi
  done
  if [[ -z "$WARP_EP" && -n "$WARP_FALLBACK_EP" ]]; then
    warn "Ни один эндпоинт не дал выход в $WANT_LOC (лучшее: ${WARP_FALLBACK_INFO%% *})."
    read -rp "${Q}Всё равно включить WARP со страной ${WARP_FALLBACK_INFO%% *}? [y/N]: " _wa
    if [[ "$_wa" =~ ^[Yy]$ ]]; then WARP_EP="$WARP_FALLBACK_EP"; WARP_EXIT_INFO="$WARP_FALLBACK_INFO"; fi
  fi
  if [[ -n "$WARP_EP" ]]; then
    WARP_OUTBOUND_FILE="$WORK_DIR/warp-outbound.json"
    warp_outbound "$WARP_EP" "$WARP_OUTBOUND_FILE"
    log "WARP: эндпоинт $WARP_EP, выход ${WARP_EXIT_INFO%% *} (${WARP_EXIT_INFO#* })."
  else
    warn "WARP не подключается или страна не подходит — продолжаю без WARP."
    warn "Проверь, что исходящий UDP на порт 2408 не режется хостером."
    WARP_MODE="off"
  fi
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

step "Панель: профиль, нода, хосты"
# ---------------------------------------------------------------------------
# Провижининг в панели: профиль (6 инбаундов) + СОЗДАНИЕ ноды + хосты + сквады
# ---------------------------------------------------------------------------
cat > "$WORK_DIR/deploy.py" <<'DEPLOYEOF'
#!/usr/bin/env python3
"""Создаёт профиль, САМУ НОДУ (через API, забирает SECRET_KEY), хосты,
добавляет инбаунды в сквады. Печатает SECRET_KEY и UUID для bash. by qellyka"""
import json, os, re, sys, urllib.error, urllib.request

PANEL = os.environ["RW_PANEL_URL"].rstrip("/"); TOKEN = os.environ["RW_API_TOKEN"]

_TTY = sys.stderr.isatty() and not os.environ.get("NO_COLOR")
def _c(code, t): return f"\033[{code}m{t}\033[0m" if _TTY else t
def elog(m):
    t = str(m)
    mm = re.match(r"\[(\d+/\d+|\d+b)\]\s*(.*)", t)
    if mm:
        print("  " + _c("38;5;80", "›") + " " + mm.group(2), file=sys.stderr)
    elif "[ERROR]" in t:
        print("  " + _c("38;5;203", "✗ " + t.replace("[ERROR]", "").strip()), file=sys.stderr)
    elif "[WARN]" in t:
        print("    " + _c("38;5;221", "⚠ " + t.replace("[WARN]", "").strip()), file=sys.stderr)
    else:
        print("    " + _c("2", "· " + t.strip()), file=sys.stderr)
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
SELF_STEAL = os.environ.get("RW_SELF_STEAL") == "true"
# self-steal: неавторизованные подключения Reality отдаёт СВОЕМУ nginx (сайт
# с настоящим LE-сертификатом домена) + PROXY protocol, чтобы nginx видел IP.
R_DEST = f"127.0.0.1:{os.environ.get('RW_PORT_SS_LOCAL', '9443')}" if SELF_STEAL else f"{SNI}:443"
R_XVER = 1 if SELF_STEAL else 0
SUFFIX = os.environ["RW_TAG_SUFFIX"]
LISTEN6 = "::" if os.environ.get("RW_HAS_V6") == "true" else "0.0.0.0"
COUNTRY = (os.environ.get("RW_COUNTRY_CODE") or "XX").upper()

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
_rkeys = get_reality_keys(3)
grpc_key = _rkeys[0]
xhttp_key = _rkeys[1]
bridge_key = _rkeys[2]
grpc_sid = os.environ["RW_SID_GRPC"]; xhttp_sid = os.environ["RW_SID_XHTTP"]
xhttp_path = os.environ["RW_XHTTP_PATH"]

T_GRPC, T_XHTTP = f"reality-grpc-{SUFFIX}", f"reality-xhttp-{SUFFIX}"
T_HY2, T_CDN, T_BRIDGE = f"hysteria2-{SUFFIX}", f"cdn-xhttp-{SUFFIX}", f"bridge-in-{SUFFIX}"
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"]}

MIN_CLIENT_VER = os.environ.get("RW_MIN_CLIENT_VER", "26.7.28")

def reality(key, sid):
    # minClientVer — только Reality: отсекает старые xray-клиенты (иначе их
    # неудачные попытки временно роняют инбаунд). Значение = ядро ноды.
    r = {"dest": R_DEST, "show": False, "xver": R_XVER,
         "shortIds": [sid], "privateKey": key, "serverNames": [SNI]}
    if MIN_CLIENT_VER:
        r["minClientVer"] = MIN_CLIENT_VER
    return r

# Рабочий набор (проверено вживую на клиенте Happ): gRPC, Hysteria2,
# Reality-XHTTP, + CDN-XHTTP через Yandex. Reality-TCP+Vision убран целиком —
# не поднимается ни в одном клиенте.
inbounds = [
    # gRPC + Reality — проверено, работает везде
    {"tag": T_GRPC, "port": P_GRPC, "listen": LISTEN6, "protocol": "vless",
     "settings": {"clients": [], "decryption": "none"},
     "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
     "streamSettings": {"network": "grpc", "security": "reality",
                        "grpcSettings": {"serviceName": "grpc"},
                        "realitySettings": reality(grpc_key, grpc_sid)}},
    # Hysteria2 — из покупного (серт файлом, alpn h3); нужен UDP-порт открыт
    {"tag": T_HY2, "port": P_HY2, "listen": LISTEN6, "protocol": "hysteria",
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
    # Мост для каскада: VLESS + Reality + XHTTP. Голый VLESS/TCP (как было)
    # или SS через границу ТСПУ распознаёт сразу; Reality выглядит как TLS.
    # minClientVer не ставим — клиент тут наш же Xray на входной ноде.
    br = {"dest": R_DEST, "show": False, "xver": R_XVER,
          "shortIds": [os.environ["RW_SID_BRIDGE"]], "privateKey": bridge_key, "serverNames": [SNI]}
    inbounds.append(
        {"tag": T_BRIDGE, "port": P_BRIDGE, "listen": "0.0.0.0", "protocol": "vless",
         "settings": {"clients": [], "decryption": "none"},
         "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
         "streamSettings": {"network": "xhttp", "security": "reality", "realitySettings": br,
             "xhttpSettings": {"path": os.environ["RW_BRIDGE_PATH"], "mode": "auto"}}})

safe = re.sub(r"[^A-Za-z0-9_\s-]", "-", NODE_DOMAIN)
rnd = (SUFFIX.split("-")[-1] or os.urandom(3).hex())[:6]
# Уникальное имя (домен + рандом) — чтобы повторный прогон не ловил 409.
PROFILE_NAME = (f"node-{safe}"[:23].rstrip("-")) + "-" + rnd

profile_outbounds = [{"tag": "direct", "protocol": "freedom"},
                     {"tag": "block", "protocol": "blackhole"}]
profile_rules = [
    # Клиенты НЕ должны ходить в локальную сеть/метадату сервера (169.254.169.254 и т.п.)
    {"ip": ["geoip:private"], "type": "field", "outboundTag": "block"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}]

EXIT_FILE = os.environ.get("RW_EXIT_FILE", "")
if EXIT_FILE and os.path.exists(EXIT_FILE):
    ex = json.load(open(EXIT_FILE))
    profile_outbounds.append({
        "tag": "to-exit", "protocol": "vless",
        "settings": {"vnext": [{"address": ex["address"], "port": int(ex["port"]),
                                "users": [{"id": ex["uuid"], "encryption": "none"}]}]},
        "streamSettings": {"network": "xhttp", "security": "reality",
            "realitySettings": {"serverName": ex["sni"], "publicKey": ex["publicKey"],
                                "shortId": ex["shortId"], "fingerprint": "chrome"},
            "xhttpSettings": {"path": ex["path"], "mode": "auto"}}})
    # RU — напрямую с входа (российский IP), если включено; остальное — в выход.
    if os.environ.get("RW_ENTRY_RU_DIRECT") == "true":
      profile_rules += [
        {"type": "field", "domain": ["geosite:category-ru", "domain:ru", "domain:su",
                                     "domain:xn--p1ai", "domain:yandex.com", "domain:yandex.net",
                                     "domain:yastatic.net", "domain:vk.com", "domain:userapi.com",
                                     "domain:mycdn.me", "domain:vkuser.net"],
         "outboundTag": "direct"},
        {"type": "field", "ip": ["geoip:ru"], "outboundTag": "direct"}]
    profile_rules.append({"type": "field", "network": "tcp,udp", "outboundTag": "to-exit"})
    rd = "RU напрямую, остальное" if os.environ.get("RW_ENTRY_RU_DIRECT") == "true" else "весь трафик"
    elog(f"  Каскад: {rd} -> {ex['node']} ({ex['address']}:{ex['port']})")

WARP_MODE = os.environ.get("RW_WARP_MODE", "off")
WARP_OUT = os.environ.get("RW_WARP_OUTBOUND", "")
if WARP_MODE != "off" and WARP_OUT and os.path.exists(WARP_OUT):
    profile_outbounds.append(json.load(open(WARP_OUT)))
    if WARP_MODE == "all":
        profile_rules.append({"type": "field", "network": "tcp,udp", "outboundTag": "warp"})
        elog("  WARP: весь трафик клиентов уходит через Cloudflare.")
    else:
        doms = [d for d in os.environ.get("RW_WARP_DOMAINS", "").split(",") if d]
        profile_rules.append({"type": "field", "domain": [f"domain:{d}" for d in doms],
                              "outboundTag": "warp"})
        elog(f"  WARP: через Cloudflare идут {len(doms)} доменов, остальное напрямую.")

profile_config = {
    "log": {"loglevel": "warning"},
    "dns": {"servers": [{"address": "8.8.8.8", "skipFallback": False}], "queryStrategy": "UseIPv4"},
    "inbounds": inbounds,
    "outbounds": profile_outbounds,
    # IPIfNonMatch (резолв каждого домена ради geoip) нужен только входу с geoip:ru;
    # на обычной ноде это лишний DNS-запрос на каждое соединение.
    "routing": {"domainStrategy": "IPIfNonMatch" if os.environ.get("RW_ENTRY_RU_DIRECT") == "true" and EXIT_FILE else "AsIs",
                "rules": profile_rules},
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
# В пользовательские сквады мост НЕ добавляем: иначе UUID всех клиентов
# попадут в bridge-inbound. К мосту имеет доступ только сервисный юзер.
squad_uuids = [tag_uuid[t] for t in active_tags if t != T_BRIDGE]

elog("[4/7] Создаю НОДУ в панели...")
# Поля сверены с CreateNodeRequestDto (required: name, address, configProfile).
node_body = {
    "name": NODE_NAME,
    "address": NODE_ADDRESS,
    "port": NODE_PORT,
    "countryCode": COUNTRY if len(COUNTRY) == 2 else "XX",
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
    r = api("POST", "/api/internal-squads", {"name": NEW_SQUAD_NAME, "inbounds": squad_uuids}, fatal=False)
    if "__error__" not in r:
        newu = (r.get("response") or r).get("uuid", "?")
        elog(f"      Создан сквад '{NEW_SQUAD_NAME}' -> {newu} с {len(squad_uuids)} инбаундами.")
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
                merged = list(dict.fromkeys(cur + squad_uuids))
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
            if str(s.get("name", "")).startswith("bridge-"):
                continue  # служебный сквад моста — только сервисный юзер
            cur = [ib["uuid"] if isinstance(ib, dict) else ib for ib in (s.get("inbounds") or [])]
            merged = list(dict.fromkeys(cur + squad_uuids))
            pl = {"uuid": s["uuid"], "name": s.get("name"), "inbounds": merged}
            r = api("PATCH", f"/api/internal-squads/{s['uuid']}", pl, fatal=False)
            if "__error__" in r: r = api("PATCH", "/api/internal-squads", pl, fatal=False)
            if "__error__" not in r: done = True; elog(f"      Squad '{s.get('name')}' обновлён.")
            else: elog(f"      [WARN] Squad '{s.get('name')}': {r['__error__']}")
    if not done:
        elog("      [WARN] Ни один сквад не обновлён — включи инбаунды в UI (Internal Squads).")

if ENABLE_BRIDGE:
    import datetime
    elog("[6b] Мост: сквад и сервисный пользователь...")
    bsuffix = T_BRIDGE[len("bridge-in-"):]
    bsq_name = f"bridge-{bsuffix}"[:30]
    r = api("POST", "/api/internal-squads", {"name": bsq_name, "inbounds": [tag_uuid[T_BRIDGE]]}, fatal=False)
    if "__error__" in r:
        elog(f"      [WARN] сквад моста не создан: {r['__error__']}")
    else:
        bsq_uuid = (r.get("response") or r).get("uuid")
        uname = f"bridge-{bsuffix}"[:36]
        body = {"username": uname, "status": "ACTIVE", "trafficLimitBytes": 0,
                "trafficLimitStrategy": "NO_RESET",
                "expireAt": "2099-12-31T00:00:00.000Z",
                "activeInternalSquads": [bsq_uuid],
                "description": f"service user: cascade bridge of {NODE_NAME}"}
        ru = api("POST", "/api/users", body, fatal=False)
        if "__error__" in ru:
            elog(f"      [WARN] сервисный пользователь не создан: {ru['__error__']}")
        else:
            elog(f"      Сквад '{bsq_name}' + пользователь '{uname}' (до 2099, без лимита).")

elog("[7/7] Готово (панель).")
# stdout — только машиночитаемое для bash:
out = {"nodeUuid": NODE_UUID, "profileUuid": PROFILE_UUID, "secretKey": SECRET_KEY or "", "nodeName": NODE_NAME}
json.dump(out, open(os.environ["RW_RESULT_FILE"], "w"))
print(json.dumps(out))
DEPLOYEOF

TAG_SUFFIX="$(echo "$NODE_DOMAIN" | tr -cd 'A-Za-z0-9' | cut -c1-12)-$(openssl rand -hex 3)"
NODE_ADDRESS="${PUBLIC_IP:-$NODE_DOMAIN}"

log "Создаю профиль, ноду и хосты в панели..."
env RW_RESULT_FILE="$WORK_DIR/result.json" RW_CDN_HOST_NAME="$CDN_HOST_NAME" \
  RW_WARP_MODE="$WARP_MODE" RW_WARP_OUTBOUND="$WARP_OUTBOUND_FILE" RW_WARP_DOMAINS="$WARP_DOMAINS" \
  RW_EXIT_FILE="$EXIT_FILE" RW_ENTRY_RU_DIRECT="$ENTRY_RU_DIRECT" RW_SID_BRIDGE="$(openssl rand -hex 8)" RW_BRIDGE_PATH="/$(openssl rand -hex 8)/" \
  RW_NODE_NAME="$NODE_NAME" RW_NODE_DOMAIN="$NODE_DOMAIN" RW_NODE_ADDRESS="$NODE_ADDRESS" \
  RW_NODE_PORT="$NODE_PORT" RW_HOST_PREFIX="$HOST_PREFIX" RW_TAG_SUFFIX="$TAG_SUFFIX" \
  RW_SNI_DONOR="$SNI_DONOR" RW_SELF_STEAL="$SELF_STEAL" RW_PORT_SS_LOCAL="$PORT_SS_LOCAL" RW_ENABLE_CDN="$ENABLE_CDN" RW_ENABLE_BRIDGE="$ENABLE_BRIDGE" \
  RW_MIN_CLIENT_VER="$MIN_CLIENT_VER" \
  RW_SQUAD_MODE="$SQUAD_MODE" RW_SQUAD_UUIDS="$SQUAD_UUIDS" RW_NEW_SQUAD_NAME="$NEW_SQUAD_NAME" \
  RW_CDN_PUBLIC_DOMAIN="$CDN_PUBLIC_DOMAIN" RW_CDN_PATH="$CDN_PATH" \
  RW_PORT_REALITY_GRPC="$PORT_REALITY_GRPC" \
  RW_PORT_REALITY_XHTTP="$PORT_REALITY_XHTTP" RW_PORT_HY2="$PORT_HY2" \
  RW_PORT_CDN_LOCAL="$PORT_CDN_LOCAL" RW_PORT_BRIDGE="$PORT_BRIDGE" \
  RW_SID_GRPC="$(openssl rand -hex 8)" \
  RW_SID_XHTTP="$(openssl rand -hex 8)" RW_XHTTP_PATH="/$(openssl rand -hex 8)/" \
  RW_HAS_V6="$HAS_V6" RW_COUNTRY_CODE="${COUNTRY_CODE:-$ENTRY_CC}" \
  python3 "$WORK_DIR/deploy.py" >/dev/null || die "Провижининг в панели не прошёл (см. ошибку выше)."
NODE_NAME=$(python3 -c "import json;print(json.load(open('$WORK_DIR/result.json'))['nodeName'])")

NODE_UUID=$(python3 -c "import json;print(json.load(open('$WORK_DIR/result.json'))['nodeUuid'])")
PROFILE_UUID=$(python3 -c "import json;print(json.load(open('$WORK_DIR/result.json'))['profileUuid'])")
SECRET_KEY=$(python3 -c "import json;print(json.load(open('$WORK_DIR/result.json'))['secretKey'])")

# SECRET_KEY (общий ключ панели из /api/keygen) мог не прийти — попросим из UI.
if [[ -z "$SECRET_KEY" ]]; then
  warn "Панель не отдала ключ через /api/keygen (зависит от версии)."
  echo "  Возьми его в панели: любая нода -> 'Copy docker-compose.yml' (значение SECRET_KEY),"
  echo "  либо страница генерации ключа. Он одинаков для всех нод этой панели."
  read -rp "${Q}SECRET_KEY: " SECRET_KEY
  SECRET_KEY="$(echo "$SECRET_KEY" | tr -d '[:space:]\"')"
  [[ -n "$SECRET_KEY" ]] || die "Без SECRET_KEY нода не подключится."
fi

# ---------------------------------------------------------------------------
# Боевой Nginx (заглушка + камуфляж 8443 + origin CDN)
# ---------------------------------------------------------------------------
log "Пишу боевой конфиг Nginx..."
# Повторный прогон со сменой маскировки: старый контейнер может держать :443,
# который теперь нужен nginx (или наоборот) — останавливаем его заранее.
if [[ -f "$NODE_DIR/docker-compose.yml" ]]; then
  docker compose -f "$NODE_DIR/docker-compose.yml" down >/dev/null 2>&1 || true
fi
# nginx >= 1.25.1: "listen ... http2" устарел, нужен "http2 on;".
NGX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [[ -n "$NGX_VER" ]] && [[ "$(printf '%s\n1.25.1\n' "$NGX_VER" | sort -V | head -1)" == "1.25.1" ]]; then
  NGX_H2_LISTEN=""; NGX_H2_DIRECTIVE="    http2 on;"
else
  NGX_H2_LISTEN=" http2"; NGX_H2_DIRECTIVE=""
fi
if [[ "$SELF_STEAL" == "true" ]]; then
  # Публичный 443 занимает Reality; nginx — только локально, за ним.
  NGX_TLS_LISTEN="    listen 127.0.0.1:$PORT_SS_LOCAL ssl${NGX_H2_LISTEN} proxy_protocol default_server;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;"
else
  NGX_TLS_LISTEN="    listen 443 ssl${NGX_H2_LISTEN} default_server;
    listen [::]:443 ssl${NGX_H2_LISTEN} default_server;"
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
    echo "  upstream xray_xhttp { server 127.0.0.1:$PORT_CDN_LOCAL; keepalive 128; }"
  fi
  cat <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
${NGX_TLS_LISTEN}
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
[[ "$HAS_V6" == "true" ]] || sed -i '/listen \[::\]/d' /etc/nginx/sites-available/default /etc/nginx/conf.d/hy2-ping.conf
nginx -t || die "Итоговый конфиг Nginx не проходит проверку"
systemctl reload nginx 2>/dev/null || systemctl restart nginx
ok "Nginx готов: https://$NODE_DOMAIN отдаёт заглушку."

step "Запуск ноды"
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
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    env_file:
      - .env
    volumes:
      - /etc/nginx/ssl:/etc/nginx/ssl:ro
EOF
spin "Поднимаю контейнер remnanode" docker compose -f "$NODE_DIR/docker-compose.yml" up -d \
  || warn "docker compose up вернул ошибку — проверь: docker logs remnanode"


step "Фаервол и продление сертификата"
# ---------------------------------------------------------------------------
# Firewall — политика drop совместима (правила в существующую inet filter input)
# ---------------------------------------------------------------------------
FW_TCP="$(printf '%s\n' "$PORT_REALITY_GRPC" "$PORT_REALITY_XHTTP" 80 443 8443 | sort -un | paste -sd, - | sed 's/,/, /g')"
# IP входных нод хранятся в файле — новый вход добавляется одной строкой
# без переустановки: echo IP >> $PEERS_FILE && /usr/local/bin/rw-node-firewall.sh
PEERS_FILE="$NODE_DIR/bridge-peers"
BRIDGE_RULES=""
if [[ "$ENABLE_BRIDGE" == "true" ]]; then
  : > "$PEERS_FILE"
  for ip in $BRIDGE_PEERS; do printf '%s\n' "$ip" >> "$PEERS_FILE"; done
  BRIDGE_RULES="if [ -s $PEERS_FILE ]; then
  while read -r ip; do [ -n \"\$ip\" ] && nft insert rule inet filter input ip saddr \"\$ip\" tcp dport $PORT_BRIDGE accept comment \"rw-node-bridge\"; done < $PEERS_FILE
else
  nft insert rule inet filter input tcp dport $PORT_BRIDGE accept comment \"rw-node-bridge\"
fi"
fi

# Чистый сервер без фаервола: предлагаем базовый nftables (drop всего входящего,
# кроме SSH, loopback, ICMP, установленных соединений и портов ноды).
FW_KIND="none"
if command -v nft >/dev/null 2>&1 && nft list table inet filter >/dev/null 2>&1; then FW_KIND="nft"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then FW_KIND="ufw"
fi
if [[ "$FW_KIND" == "none" ]] && command -v nft >/dev/null 2>&1; then
  SSH_PORTS=$( { ss -tlnpH 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/';
                 grep -hiE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}';
                 echo 22; } | sort -un | paste -sd, - | sed 's/,/, /g')
  warn "Фаервол не найден — сейчас открыты ВСЕ порты сервера."
  echo "  Могу включить базовый nftables: входящее закрыто, кроме SSH ($SSH_PORTS) и портов ноды."
  read -rp "${Q}Включить базовый фаервол? [Y/n]: " _fw
  if [[ ! "$_fw" =~ ^[Nn]$ ]]; then
    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Базовый фаервол от remnanode-deploy.sh. Порты ноды добавляет rw-node-firewall.service.
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iif lo accept
    meta l4proto { icmp, ipv6-icmp } accept
    tcp dport { $SSH_PORTS } accept comment "ssh"
  }
  chain forward { type filter hook forward priority 0; policy accept; }
  chain output  { type filter hook output priority 0; policy accept; }
}
EOF
    if nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf; then
      systemctl enable nftables >/dev/null 2>&1 || true
      # Docker кладёт свои правила в iptables(-nft) — после flush перезапускаем.
      systemctl restart docker >/dev/null 2>&1 || true
      FW_KIND="nft"; ok "Базовый nftables включён (SSH: $SSH_PORTS)."
    else
      warn "Не смог применить базовый nftables — оставляю без фаервола."
    fi
  fi
fi
NODEPORT_RULE=""
if [[ -n "$PANEL_IP" ]]; then
  NODEPORT_RULE="nft insert rule inet filter input ip saddr $PANEL_IP tcp dport $NODE_PORT accept comment \"rw-node-nodeport\""
else
  NODEPORT_RULE="nft insert rule inet filter input tcp dport $NODE_PORT accept comment \"rw-node-nodeport\""
fi

if [[ "$FW_KIND" == "nft" ]]; then
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
elif [[ "$FW_KIND" == "ufw" ]]; then
  log "Открываю порты в ufw..."
  for p in $(printf '%s\n' "$PORT_REALITY_GRPC" "$PORT_REALITY_XHTTP" 80 443 8443 | sort -un); do ufw allow "$p"/tcp >/dev/null 2>&1 || true; done
  ufw allow "$PORT_HY2"/udp >/dev/null 2>&1 || true
  if [[ -n "$PANEL_IP" ]]; then ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null 2>&1 || true
  else ufw allow "$NODE_PORT"/tcp >/dev/null 2>&1 || true; fi
  if [[ "$ENABLE_BRIDGE" == "true" ]]; then
    if [[ -n "$BRIDGE_PEERS" ]]; then for ip in $BRIDGE_PEERS; do ufw allow from "$ip" to any port "$PORT_BRIDGE" proto tcp >/dev/null 2>&1 || true; done
    else ufw allow "$PORT_BRIDGE"/tcp >/dev/null 2>&1 || true; fi
  fi
else
  warn "Сервер без фаервола: все порты открыты. NODE_PORT $NODE_PORT защищён только SECRET_KEY."
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

step "Проверка связи с панелью"
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
  NODE_ONLINE=true; ok "Нода подключена к панели."
else
  NODE_ONLINE=false
  warn "Панель пока не видит ноду: ${NODE_STATUS:-нет ответа}"
  warn "Проверь: docker logs remnanode --tail 50, NODE_PORT $NODE_PORT открыт для ${PANEL_IP:-панели}, SECRET_KEY верный."
fi

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
case "$NODE_ROLE:$ENABLE_BRIDGE" in
  entry:*)   ROLE_TXT="входная нода каскада → $EXIT_NAME ($EXIT_CC)" ;;
  exit:true) ROLE_TXT="обычная нода + выход каскада (мост)" ;;
  *)         ROLE_TXT="обычная нода" ;;
esac

printf '\n'
if [[ "$NODE_ONLINE" == "true" ]]; then
  printf '  %s%s✓ Готово! Нода %s ONLINE в панели%s\n' "$C_GRN" "$C_B" "$NODE_NAME" "$C_RST"
else
  printf '  %s%s⚠ Установка завершена, но панель пока не видит ноду%s\n' "$C_YEL" "$C_B" "$C_RST"
  printf '  %s  проверь: docker logs remnanode --tail 50%s\n' "$C_DIM" "$C_RST"
fi

printf '\n  %s╭─ Нода%s\n' "$C_MAG" "$C_RST"
kv "Имя"        "$NODE_NAME"
kv "Роль"       "$ROLE_TXT"
kv "Домен"      "https://$NODE_DOMAIN  (сайт-заглушка)"
kv "UUID"       "$NODE_UUID"
kv "Профиль"    "$PROFILE_UUID"
if [[ "$SELF_STEAL" == "true" ]]; then
  kv "Маскировка" "self-steal · SNI $SNI_DONOR · сайт за Reality на 443"
else
  kv "Маскировка" "SNI-донор $SNI_DONOR"
fi
[[ -n "$HOST_PREFIX" ]] && kv "Хосты" "$HOST_PREFIX …"
if [[ "$WARP_MODE" != "off" ]]; then
  kv "WARP" "$WARP_MODE · выход ${WARP_EXIT_INFO%% *} (${WARP_EXIT_INFO#* })"
fi
if [[ "$NODE_ROLE" == "entry" ]]; then
  _rd="весь трафик → выход"
  [[ "$ENTRY_RU_DIRECT" == "true" ]] && _rd="RU-сайты напрямую ($ENTRY_CC), остальное → выход"
  kv "Каскад" "$_rd"
fi
printf '  %s╰─%s\n' "$C_MAG" "$C_RST"

printf '\n  %s╭─ Инбаунды%s\n' "$C_MAG" "$C_RST"
kv "Reality gRPC"  "TCP $PORT_REALITY_GRPC"
kv "Reality XHTTP" "TCP $PORT_REALITY_XHTTP$([[ "$SELF_STEAL" == "true" ]] && echo "  (self-steal, сайт-заглушка за ним)")"
kv "Hysteria2"     "UDP $PORT_HY2  (UDP должен быть открыт у хостера)"
[[ "$ENABLE_CDN" == "true" ]]    && kv "CDN XHTTP" "Yandex CDN → nginx → 127.0.0.1:$PORT_CDN_LOCAL"
[[ "$ENABLE_BRIDGE" == "true" ]] && kv "Мост" "TCP $PORT_BRIDGE · VLESS+Reality+XHTTP · только сервисный юзер"
printf '  %s╰─%s\n' "$C_MAG" "$C_RST"

if [[ "$ENABLE_BRIDGE" == "true" ]]; then
  printf '\n  %s╭─ Каскад: эта нода — выход%s\n' "$C_BLU" "$C_RST"
  kv "Дальше" "поставь входную ноду этим же скриптом, роль 2 —"
  kv ""       "она сама найдёт этот выход в панели"
  if [[ -n "$BRIDGE_PEERS" ]]; then kv "Порт моста" "$PORT_BRIDGE открыт только для: $BRIDGE_PEERS"
  else kv "Порт моста" "$PORT_BRIDGE открыт всем (защищён Reality + UUID)"; fi
  if [[ -n "$BRIDGE_PEERS" && "$FW_KIND" == "nft" ]]; then
    kv "Новый вход" "echo IP >> $PEERS_FILE && /usr/local/bin/rw-node-firewall.sh"
  elif [[ -n "$BRIDGE_PEERS" && "$FW_KIND" == "ufw" ]]; then
    kv "Новый вход" "ufw allow from IP to any port $PORT_BRIDGE proto tcp"
  fi
  printf '  %s╰─%s\n' "$C_BLU" "$C_RST"
fi

if [[ "$ENABLE_CDN" == "true" ]]; then
  printf '\n  %s╭─ Осталось руками: Yandex Cloud CDN%s\n' "$C_YEL" "$C_RST"
  if [[ "$NODE_ROLE" == "entry" ]]; then
    kv "Схема" "клиент → CDN → $NODE_DOMAIN (вход) → мост → $EXIT_NAME (выход)"
    kv "Важно" "источник CDN — ВХОДНОЙ сервер (этот), не выход"
  elif [[ "$ENABLE_BRIDGE" == "true" ]]; then
    kv "Схема" "клиент → CDN → $NODE_DOMAIN напрямую (в обход каскада)"
    kv "Важно" "для каскада CDN настраивают на входной ноде"
  else
    kv "Схема" "клиент → CDN → $NODE_DOMAIN"
  fi
  kv "1. Сертификат" "Certificate Manager → LE для $CDN_PUBLIC_DOMAIN (DNS-валидация)"
  kv "2. Источник"   "CDN → Группы источников → $NODE_DOMAIN, HTTPS"
  kv "3. Ресурс"     "домен $CDN_PUBLIC_DOMAIN, источник из п.2, серт из п.1,"
  kv ""              "к источнику HTTPS, Host = $NODE_DOMAIN, кэш и сжатие ВЫКЛ"
  kv "4. DNS"        "CNAME $CDN_PUBLIC_DOMAIN → cl-xxxxx.edgecdn.ru (из консоли)"
  kv "Путь XHTTP"    "$CDN_PATH"
  printf '  %s╰─%s\n' "$C_YEL" "$C_RST"
fi

printf '\n  %sПолный лог установки: %s%s\n\n' "$C_DIM" "$LOG_FILE" "$C_RST"
