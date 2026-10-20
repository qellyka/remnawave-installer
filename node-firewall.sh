#!/usr/bin/env bash
# =============================================================================
#  node-firewall.sh — включить фаервол на УЖЕ работающей ноде Remnawave
#  (без переустановки). Что делает:
#    - порт ноды (NODE_PORT) открывает ТОЛЬКО для IP панели;
#    - для интернета оставляет лишь порты, которые реально слушают Xray и
#      веб-сервер заглушки (+ 80 для выпуска сертификата), всё остальное — DROP;
#    - порт моста каскада (если есть) — только для IP входных нод;
#    - SSH не отрезает: правила действуют с АВТООТКАТОМ — если за 60 секунд
#      ты не подтвердил, что SSH жив, фаервол снимается сам;
#    - чужие таблицы (Docker, remnanode) не трогает.
#  Запуск на сервере с нодой:
#     bash <(curl -fsSL https://raw.githubusercontent.com/qellyka/remnawave-installer/main/node-firewall.sh)
#  Переменные: PANEL_IP, NODE_PORT, BRIDGE_PORT, BRIDGE_PEERS, ROLLBACK_SEC=60,
#              DRY_RUN=1 (только показать и проверить правила, ничего не применять)
# =============================================================================
set -euo pipefail

NODE_DIR="${NODE_DIR:-/opt/remnanode}"
ROLLBACK_SEC="${ROLLBACK_SEC:-60}"
CONF="${NFT_CONF:-/etc/nftables.conf}"
DRY_RUN="${DRY_RUN:-0}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[38;5;203m'
  C_GRN=$'\033[38;5;114m'; C_YEL=$'\033[38;5;221m'; C_CYN=$'\033[38;5;80m'; C_MAG=$'\033[38;5;177m'
else C_RST=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_MAG=""; fi
log()  { printf '  %s›%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s⚠ %s%s\n' "$C_YEL" "$*" "$C_RST"; }
die()  { printf '\n  %s%s✗ %s%s\n' "$C_RED" "$C_B" "$*" "$C_RST" >&2; exit 1; }
Q="  ${C_MAG}?${C_RST} "
is_yes() { local a; a="$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"; case "$a" in y|yes|д|да|у) return 0 ;; *) return 1 ;; esac; }
is_no()  { local a; a="$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"; case "$a" in n|no|н|нет|т) return 0 ;; *) return 1 ;; esac; }
is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:.]*$ ]]; }

# Правила "разрешить tcp-порт $1 для адресов $2..." — отдельно для IPv4 и IPv6.
saddr_rules() {
  local port="$1"; shift
  local v4=() v6=() ip
  for ip in "$@"; do if [[ "$ip" == *:* ]]; then v6+=("$ip"); else v4+=("$ip"); fi; done
  if ((${#v4[@]})); then printf '    ip saddr { %s } tcp dport %s accept\n' "$(IFS=,; echo "${v4[*]}" | sed 's/,/, /g')" "$port"; fi
  if ((${#v6[@]})); then printf '    ip6 saddr { %s } tcp dport %s accept\n' "$(IFS=,; echo "${v6[*]}" | sed 's/,/, /g')" "$port"; fi
  return 0
}

main() {
  [[ $EUID -eq 0 ]] || die "Запускай от root."
  for c in nft ss awk; do command -v "$c" >/dev/null 2>&1 || die "Нужен $c (apt install nftables iproute2)."; done
  printf '\n  %s%sФаервол для работающей ноды Remnawave%s\n\n' "$C_B" "$C_MAG" "$C_RST"

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    die "Активен ufw — настрой через него: ufw allow from <IP панели> to any port <NODE_PORT> proto tcp."
  fi
  if nft list table inet filter >/dev/null 2>&1; then
    die "Таблица inet filter уже есть, фаервол настроен. Скрипт её не трогает (смотри: nft list ruleset)."
  fi

  # --- порт ноды ---
  NODE_PORT="${NODE_PORT:-}"
  if [[ -z "$NODE_PORT" && -r "$NODE_DIR/.env" ]]; then
    NODE_PORT=$(grep -E '^NODE_PORT=' "$NODE_DIR/.env" | head -1 | cut -d= -f2 | tr -d '[:space:]"' || true)
  fi
  if ! [[ "$NODE_PORT" =~ ^[0-9]+$ ]]; then
    read -rp "${Q}Порт ноды (NODE_PORT, не нашёл в $NODE_DIR/.env): " NODE_PORT
    [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || die "NODE_PORT должен быть числом."
  fi
  ok "Порт ноды: $NODE_PORT"

  # --- IP панели: берём тех, кто сейчас подключён к порту ноды ---
  PANEL_IP="${PANEL_IP:-}"
  if [[ -z "$PANEL_IP" ]]; then
    PANEL_IP=$(ss -Htn state established "( sport = :$NODE_PORT )" 2>/dev/null \
      | awk '{a=$4; if (a ~ /^\[/) {sub(/^\[/,"",a); sub(/\]:[0-9]+$/,"",a)} else sub(/:[0-9]+$/,"",a); sub(/^::ffff:/,"",a); print a}' \
      | sort -u | head -1 || true)
    _hint="${PANEL_IP:-не определён}"
    read -rp "${Q}IP панели [$_hint] (Enter — принять): " _p
    _p="$(printf '%s' "$_p" | tr -d '[:space:]')"; [[ -n "$_p" ]] && PANEL_IP="$_p"
  fi
  is_ip "$PANEL_IP" || die "Нужен IP панели (его видно по подключению к порту $NODE_PORT или впиши вручную)."

  # --- публичные порты Xray / сайта-заглушки ---
  TCP_PORTS=(); UDP_PORTS=()
  while read -r net port; do
    [[ -n "${port:-}" && "$port" != "$NODE_PORT" ]] || continue
    case "$net" in tcp) TCP_PORTS+=("$port") ;; udp) UDP_PORTS+=("$port") ;; esac
  done < <(ss -H -tulnp 2>/dev/null | awk '{loc=$5; if (loc !~ /^(0\.0\.0\.0|\*|\[::\]):[0-9]+$/) next; if ($NF !~ /rw-core|xray|caddy|nginx|haproxy/) next; n=split(loc,a,":"); print $1, a[n]}' | sort -u)
  TCP_PORTS+=(80)   # выпуск/продление сертификата Let's Encrypt (HTTP-01) и 301 на https

  # --- мост каскада ---
  BRIDGE_PORT="${BRIDGE_PORT:-}"
  if [[ -z "$BRIDGE_PORT" && " ${TCP_PORTS[*]} " == *" 8888 "* ]]; then
    read -rp "${Q}Порт 8888 — мост каскада (BRIDGE_IN)? Откроем его только входным нодам. [y/N]: " _b
    is_yes "$_b" && BRIDGE_PORT=8888
  fi
  BRIDGE_PEERS="${BRIDGE_PEERS:-}"
  if [[ -n "$BRIDGE_PORT" ]]; then
    _keep=(); for _p in "${TCP_PORTS[@]}"; do [[ "$_p" == "$BRIDGE_PORT" ]] || _keep+=("$_p"); done
    TCP_PORTS=("${_keep[@]}")
    if [[ -z "$BRIDGE_PEERS" ]]; then
      read -rp "${Q}IP входных нод через пробел (Enter — мост закрыт для всех): " BRIDGE_PEERS
    fi
    BRIDGE_PEERS="$(printf '%s' "$BRIDGE_PEERS" | tr ',;' '  ')"
    for ip in $BRIDGE_PEERS; do is_ip "$ip" || die "«$ip» — не IP-адрес."; done
  fi

  # --- SSH ---
  SSH_PORTS=$( { ss -tlnpH 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/'
                 grep -hiE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}'
                 echo 22; } | sort -un | paste -sd, - | sed 's/,/, /g')
  SSH_RULE="    tcp dport { $SSH_PORTS } accept comment \"ssh\""
  _sship="${SSH_CLIENT:-}"; _sship="${_sship%% *}"
  if [[ -n "$_sship" ]] && is_ip "$_sship"; then
    echo "  SSH сейчас открыт любому. Могу пустить его только с твоего IP ($_sship)."
    echo "  Если IP сменится — зайти можно будет лишь через консоль хостера."
    read -rp "${Q}Ограничить SSH до $_sship? [y/N]: " _sr
    if is_yes "$_sr"; then
      if [[ "$_sship" == *:* ]]; then SSH_RULE="    ip6 saddr $_sship tcp dport { $SSH_PORTS } accept comment \"ssh\""
      else SSH_RULE="    ip saddr $_sship tcp dport { $SSH_PORTS } accept comment \"ssh\""; fi
    fi
  fi

  # --- собираем набор правил ---
  _tcp=$(printf '%s\n' "${TCP_PORTS[@]}" | grep -E '^[0-9]+$' | sort -un | paste -sd, - | sed 's/,/, /g')
  _udp=$(printf '%s\n' "${UDP_PORTS[@]:-}" | grep -E '^[0-9]+$' | sort -un | paste -sd, - | sed 's/,/, /g' || true)
  RULES="$(mktemp /tmp/rw-fw.XXXXXX)"
  {
    echo "#!/usr/sbin/nft -f"
    echo "# Фаервол ноды Remnawave (node-firewall.sh). Только своя таблица: Docker и remnanode не трогаем."
    echo "table inet filter"
    echo "delete table inet filter"
    echo "table inet filter {"
    echo "  chain input {"
    echo "    type filter hook input priority 0; policy drop;"
    echo "    ct state established,related accept"
    echo "    ct state invalid drop"
    echo "    iif lo accept"
    echo "    meta l4proto { icmp, ipv6-icmp } accept"
    echo "    udp sport 67 udp dport 68 accept"
    echo "    udp sport 547 udp dport 546 accept"
    echo "$SSH_RULE"
    echo "    tcp dport { $_tcp } accept"
    [[ -n "$_udp" ]] && echo "    udp dport { $_udp } accept"
    saddr_rules "$NODE_PORT" "$PANEL_IP"
    if [[ -n "$BRIDGE_PORT" && -n "$BRIDGE_PEERS" ]]; then
      # shellcheck disable=SC2086
      saddr_rules "$BRIDGE_PORT" $BRIDGE_PEERS
    fi
    echo "  }"
    echo "}"
  } > "$RULES"

  printf '\n  %s╭─ План%s\n' "$C_MAG" "$C_RST"
  printf '  %s│%s порт ноды %s открыт только для %s\n' "$C_DIM" "$C_RST" "$NODE_PORT" "$PANEL_IP"
  printf '  %s│%s публично: TCP %s%s\n' "$C_DIM" "$C_RST" "$_tcp" "${_udp:+, UDP $_udp}"
  [[ -n "$BRIDGE_PORT" ]] && printf '  %s│%s мост %s: %s\n' "$C_DIM" "$C_RST" "$BRIDGE_PORT" "${BRIDGE_PEERS:-закрыт для всех}"
  printf '  %s│%s SSH: %s\n' "$C_DIM" "$C_RST" "$(sed -E 's/^ +//; s/ accept.*//' <<<"$SSH_RULE")"
  printf '  %s╰─%s остальное — DROP\n\n' "$C_MAG" "$C_RST"

  nft -c -f "$RULES" || { rm -f "$RULES"; die "Правила не прошли проверку nft — ничего не применено."; }
  ok "Правила прошли проверку синтаксиса."
  if [[ "$DRY_RUN" == "1" ]]; then echo; cat "$RULES"; rm -f "$RULES"; echo; ok "DRY_RUN: ничего не применено."; return 0; fi

  read -rp "${Q}Применить? [Y/n]: " _go
  if is_no "$_go"; then rm -f "$RULES"; die "Отменено."; fi

  # --- применяем с автооткатом ---
  FLAG="/run/rw-fw-ok.$$"; rm -f "$FLAG"
  setsid nohup bash -c "sleep $ROLLBACK_SEC; [ -e '$FLAG' ] || nft delete table inet filter 2>/dev/null" >/dev/null 2>&1 &
  nft -f "$RULES"
  ok "Правила применены."
  echo "  Не закрывай это окно: открой ВТОРОЙ SSH-сеанс и проверь, что он подключается."
  echo "  Если всё работает — подтверди здесь. Иначе через $ROLLBACK_SEC с фаервол снимется сам."
  _c=""; read -t "$ROLLBACK_SEC" -rp "${Q}SSH жив? Введи y, чтобы закрепить: " _c || true
  if is_yes "$_c"; then
    : > "$FLAG"
    [[ -f "$CONF" ]] && cp -p "$CONF" "$CONF.bak-$(date +%s)"
    cp "$RULES" "$CONF"; chmod 644 "$CONF"
    systemctl enable nftables >/dev/null 2>&1 || true
    ok "Фаервол закреплён: $CONF (переживёт перезагрузку)."
  else
    warn "Подтверждения нет — фаервол будет снят автоматически (или уже снят)."
  fi
  rm -f "$RULES"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
