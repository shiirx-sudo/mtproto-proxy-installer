#!/usr/bin/env bash
#
# MTProto Proxy installer (DPI-resistant: Fake TLS `ee` / Secure `dd`)
# Backend: telemt (https://github.com/telemt/telemt)
#
# One-command install:
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh)
#
# This script is self-contained: it generates the config, the systemd unit
# and the `mtproto-proxy-manager` management tool.
#
# It DOES NOT promise "undetectability". MTProto + Fake TLS *reduces* the
# probability of DPI detection, it does not guarantee bypass. See README.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Constants & defaults (overridable via environment)
# ----------------------------------------------------------------------------
TELEMT_REPO="${TELEMT_REPO:-telemt/telemt}"
TELEMT_VERSION="${TELEMT_VERSION:-3.3.28}"   # pinned by default; updatable later
TELEMT_SHA256="${TELEMT_SHA256:-}"           # operator-pinned hash (strongest)
ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-false}"

CONF_DIR="/etc/mtproto-proxy"
CONFIG_PATH="${CONF_DIR}/telemt.toml"
ENV_PATH="${CONF_DIR}/installer.env"
LINKS_PATH="${CONF_DIR}/links.txt"
BACKUP_DIR="${CONF_DIR}/backups"
BIN_PATH="/usr/local/bin/telemt"
MANAGER_PATH="/usr/local/bin/mtproto-proxy-manager"
SERVICE_NAME="mtproto-proxy"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
PROXY_USER="mtproxy"
PROXY_HOME="/var/lib/mtproto-proxy"
API_ADDR="127.0.0.1:9091"
PROXY_USERNAME="user"                        # key in [access.users]

# Defaults that the operator can change interactively or via env
PORT="${PORT:-443}"
MASK_DOMAIN="${MASK_DOMAIN:-vk.com}"   # SNI / tls_domain to masquerade as
CONN_HOST="${CONN_HOST:-}"                    # IP or domain put into the link
DEPLOY="${DEPLOY:-systemd}"                   # systemd | docker
ENABLE_BBR="${ENABLE_BBR:-ask}"              # ask | true | false
INSECURE_DIAGNOSTIC_ONLY="${INSECURE_DIAGNOSTIC_ONLY:-false}"
ASSUME_YES="${ASSUME_YES:-false}"
PROTECT_SSH="${PROTECT_SSH:-ask}"

# ----------------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_RST=$'\033[0m'; C_BLD=$'\033[1m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_RST=""; C_BLD=""
fi
info()  { printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }

confirm() {
  # confirm "question" -> returns 0 on yes
  local q="$1"
  if [ "$ASSUME_YES" = "true" ]; then return 0; fi
  local a
  read -r -p "$q [y/N]: " a </dev/tty || a=""
  [[ "$a" =~ ^[Yy]$ ]]
}

ask() {
  # ask "prompt" "default" -> echoes answer
  local prompt="$1" def="${2:-}" a
  if [ "$ASSUME_YES" = "true" ]; then echo "$def"; return; fi
  if [ -n "$def" ]; then
    read -r -p "$prompt [$def]: " a </dev/tty || a=""
    echo "${a:-$def}"
  else
    read -r -p "$prompt: " a </dev/tty || a=""
    echo "$a"
  fi
}

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
require_root() {
  [ "$(id -u)" -eq 0 ] || die "Запустите установщик от root (sudo su / sudo bash ...)."
}

detect_os() {
  [ -r /etc/os-release ] || die "Не найден /etc/os-release — неподдерживаемая ОС."
  # shellcheck disable=SC1091
  . /etc/os-release
  local id="${ID:-}" ver="${VERSION_ID:-}"
  case "$id:$ver" in
    ubuntu:22.04|ubuntu:24.04|debian:12)
      ok "ОС поддерживается: ${PRETTY_NAME:-$id $ver}" ;;
    ubuntu:*|debian:*)
      warn "ОС ${PRETTY_NAME:-$id $ver} официально не тестировалась этим установщиком."
      confirm "Продолжить на свой риск?" || die "Остановлено пользователем." ;;
    *)
      die "Неподдерживаемая ОС: ${PRETTY_NAME:-$id $ver}. Нужны Ubuntu 22.04/24.04 или Debian 12." ;;
  esac
}

detect_arch() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|aarch64) ok "Архитектура: $ARCH" ;;
    *) die "Архитектура $ARCH не поддерживается релизами telemt (нужны x86_64 или aarch64)." ;;
  esac
  if ldd --version 2>&1 | grep -iq musl; then LIBC="musl"; else LIBC="gnu"; fi
}

install_deps() {
  info "Установка зависимостей (curl, jq, tar, openssl, ca-certificates)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq tar openssl ca-certificates iproute2 >/dev/null
  ok "Зависимости установлены."
}

# ----------------------------------------------------------------------------
# Network helpers
# ----------------------------------------------------------------------------
detect_public_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1 || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  echo "$ip"
}

resolve_a() {
  # resolve_a domain -> first A record (uses system resolver)
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}'
}

# ----------------------------------------------------------------------------
# Interactive configuration
# ----------------------------------------------------------------------------
gather_config() {
  local pub_ip
  pub_ip="$(detect_public_ip)"
  [ -n "$pub_ip" ] && info "Определён внешний IP сервера: $pub_ip" || warn "Не удалось автоматически определить внешний IP."
  SERVER_IP="$pub_ip"

  # --- Deployment mode: always systemd (docker only via explicit --docker flag) ---
  ok "Режим развёртывания: $DEPLOY"

  # --- Connection host (link address) ---
  echo
  info "Адрес подключения — это server в ссылке (IP или ваш домен, указывающий A-записью на сервер)."
  info "Это НЕ маскировочный SNI: домен здесь нужен только для адресации/красивой ссылки."
  if [ -z "$CONN_HOST" ]; then
    CONN_HOST="$(ask "Адрес подключения (IP или домен)" "${SERVER_IP:-}")"
  fi
  [ -n "$CONN_HOST" ] || die "Не указан адрес подключения."

  # If it's a domain, validate the A record
  if [[ ! "$CONN_HOST" =~ ^[0-9.]+$ ]]; then
    local a
    a="$(resolve_a "$CONN_HOST")"
    if [ -z "$a" ]; then
      warn "Домен $CONN_HOST не резолвится в A-запись. Ссылка может не работать."
    elif [ -n "$SERVER_IP" ] && [ "$a" != "$SERVER_IP" ]; then
      warn "A-запись $CONN_HOST = $a, а IP сервера = $SERVER_IP. Они не совпадают."
      confirm "Всё равно продолжить?" || die "Остановлено пользователем."
    else
      ok "A-запись $CONN_HOST совпадает с IP сервера."
    fi
    warn "Рекомендация: настройте PTR/rDNS вашего IP на домен маскировки — это повышает «легитимность» хоста."
  fi

  # --- Masquerade domain (SNI / tls_domain) ---
  echo
  info "Маскировочный домен (SNI/tls_domain) — реальный, доступный с сервера HTTPS-сайт,"
  info "под который маскируется трафик. Неаутентифицированные соединения прозрачно уходят на него."
  MASK_DOMAIN="$(ask "Маскировочный домен (SNI)" "$MASK_DOMAIN")"
  [ -n "$MASK_DOMAIN" ] || die "Не указан маскировочный домен."
  if curl -fsS -o /dev/null -m 8 "https://${MASK_DOMAIN}" 2>/dev/null; then
    ok "Маскировочный домен $MASK_DOMAIN доступен по HTTPS с сервера."
  else
    warn "Не удалось открыть https://${MASK_DOMAIN} с сервера. Выберите доступный и не заблокированный сайт."
    confirm "Продолжить с этим доменом?" || die "Остановлено пользователем."
  fi

  # --- Port ---
  echo
  info "Порт по умолчанию 443/tcp (максимально похож на обычный HTTPS)."
  info "Нестандартный порт (например 8443) допустим, но снижает «похожесть на HTTPS»."
  PORT="$(ask "Порт" "$PORT")"
  [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "Некорректный порт: $PORT"
  check_port_free

  # --- Secret mode ---
  if [ "$INSECURE_DIAGNOSTIC_ONLY" = "true" ]; then
    warn "INSECURE_DIAGNOSTIC_ONLY=true — будет включён classic (bare secret). Только для диагностики!"
  fi
}

check_port_free() {
  local lines
  lines="$(ss -lntpH "sport = :${PORT}" 2>/dev/null || true)"
  if [ -z "$lines" ]; then
    ok "Порт ${PORT}/tcp свободен."
    return
  fi

  warn "Порт ${PORT} уже занят:"
  echo "$lines" | sed 's/^/    /'

  if [ "$ASSUME_YES" = "true" ]; then
    die "Порт занят (неинтерактивный режим). Освободите порт или задайте PORT=другой."
  fi

  local choice
  choice="$(ask "Действие: [k] остановить занявший сервис / [p] другой порт / [q] выход" "q")"
  case "$choice" in
    k|K) stop_port_occupant; check_port_free ;;
    p|P) PORT="$(ask "Новый порт" "8443")"; check_port_free ;;
    *)   die "Выход. Освободите порт вручную и перезапустите установщик." ;;
  esac
}

stop_port_occupant() {
  # User-initiated (not automatic): stop the service/process holding the port.
  local pids
  pids="$(ss -lntpH "sport = :${PORT}" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
  if [ -z "$pids" ]; then
    warn "Не удалось определить PID процесса на порту ${PORT} (запущено не от root?)."
    return
  fi

  warn "ВНИМАНИЕ: остановка займёт сервис, который СЕЙЧАС использует порт ${PORT}."
  warn "Если через него (например xray) идёт ваш трафик — он прервётся. Убедитесь, что это безопасно."

  local pid unit pname
  for pid in $pids; do
    unit=""
    [ -r "/proc/$pid/cgroup" ] && unit="$(grep -oE '[a-zA-Z0-9@._-]+\.service' "/proc/$pid/cgroup" | head -1 || true)"
    pname="$(ps -o comm= -p "$pid" 2>/dev/null || echo "pid $pid")"

    if [ -n "$unit" ]; then
      if confirm "Остановить systemd-сервис ${unit} (процесс ${pname}, pid ${pid})?"; then
        if systemctl stop "$unit"; then
          ok "Остановлен ${unit}."
          if confirm "Отключить автозапуск ${unit}, чтобы он не занял порт после перезагрузки?"; then
            systemctl disable "$unit" >/dev/null 2>&1 && ok "Автозапуск ${unit} отключён." || warn "Не удалось отключить автозапуск ${unit}."
          fi
        else
          warn "Не удалось остановить ${unit}."
        fi
      fi
    else
      if confirm "Это не systemd-сервис. Отправить SIGTERM процессу ${pname} (pid ${pid})?"; then
        kill -TERM "$pid" 2>/dev/null && ok "Сигнал TERM отправлен (pid ${pid})." || warn "Не удалось завершить pid ${pid}."
      fi
    fi
  done
  sleep 2
}

# ----------------------------------------------------------------------------
# Download + integrity verification
# ----------------------------------------------------------------------------
telemt_download_verify() {
  # args: <version> <dest_binary_path>
  local ver="$1" dest="$2"
  local asset="telemt-${ARCH}-linux-${LIBC}.tar.gz"
  local base="https://github.com/${TELEMT_REPO}/releases/download/${ver}"
  local url="${base}/${asset}"
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  info "Скачивание telemt ${ver} (${asset})..."
  curl -fSL --retry 3 -o "${tmp}/${asset}" "$url" || die "Не удалось скачать $url"

  local computed
  computed="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
  info "SHA256 скачанного файла: ${computed}"

  local verified="false" expected=""
  if [ -n "$TELEMT_SHA256" ]; then
    expected="$TELEMT_SHA256"
    info "Сверка с заданным TELEMT_SHA256..."
  elif curl -fsS -m 10 -o "${tmp}/asset.sha256" "${url}.sha256" 2>/dev/null; then
    expected="$(grep -oE '[0-9a-fA-F]{64}' "${tmp}/asset.sha256" | head -1 || true)"
    [ -n "$expected" ] && info "Найден ${asset}.sha256 в релизе."
  elif curl -fsS -m 10 -o "${tmp}/SHA256SUMS" "${base}/SHA256SUMS" 2>/dev/null; then
    expected="$(grep -E "(^| )${asset}\$|  ?${asset}\$" "${tmp}/SHA256SUMS" | grep -oE '[0-9a-fA-F]{64}' | head -1 || true)"
    [ -n "$expected" ] && info "Найден SHA256SUMS в релизе."
  fi

  if [ -n "$expected" ]; then
    if [ "${computed,,}" = "${expected,,}" ]; then
      verified="true"; ok "Контрольная сумма совпала."
    else
      die "Контрольная сумма НЕ совпала! ожидалось ${expected}, получено ${computed}. Установка прервана."
    fi
  fi

  if [ "$verified" != "true" ]; then
    warn "Опубликованная контрольная сумма не найдена/не задана."
    if [ "$ALLOW_UNVERIFIED" = "true" ]; then
      warn "ALLOW_UNVERIFIED=true — продолжаю без проверки целостности."
    else
      err  "Чтобы продолжить безопасно, перезапустите с проверкой:"
      err  "  TELEMT_SHA256=${computed} bash install.sh     # если вы доверяете этому хешу"
      err  "или явно отключите проверку: ALLOW_UNVERIFIED=true bash install.sh"
      die  "Установка прервана из-за непроверенной целостности."
    fi
  fi

  tar -xzf "${tmp}/${asset}" -C "$tmp"
  local extracted
  extracted="$(find "$tmp" -maxdepth 2 -type f -name telemt | head -1 || true)"
  [ -n "$extracted" ] || die "В архиве не найден бинарник telemt."
  install -m 0755 "$extracted" "$dest"
  ok "Бинарник установлен: $dest"
}

# ----------------------------------------------------------------------------
# Users / directories / secret
# ----------------------------------------------------------------------------
create_user_dirs() {
  if ! id "$PROXY_USER" >/dev/null 2>&1; then
    useradd -r -d "$PROXY_HOME" -m -s /usr/sbin/nologin -U "$PROXY_USER"
    ok "Создан системный пользователь $PROXY_USER."
  fi
  install -d -m 0750 -o "$PROXY_USER" -g "$PROXY_USER" "$CONF_DIR"
  install -d -m 0700 -o "$PROXY_USER" -g "$PROXY_USER" "$BACKUP_DIR"
}

gen_secret() { openssl rand -hex 16; }

# ----------------------------------------------------------------------------
# Config / unit / env files
# ----------------------------------------------------------------------------
write_config() {
  local secret="$1"
  local classic="false" secure="true" tls="true"
  [ "$INSECURE_DIAGNOSTIC_ONLY" = "true" ] && classic="true"

  umask 077
  cat > "$CONFIG_PATH" <<EOF
# Generated by mtproto-proxy installer. Backend: telemt.
# Fake TLS (ee) primary, Secure (dd) fallback. classic only for diagnostics.

[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = ${classic}
secure = ${secure}
tls = ${tls}

[general.links]
show = "*"
public_host = "${CONN_HOST}"
public_port = ${PORT}

[server]
port = ${PORT}

# Local-only management API used to retrieve working links. Not exposed externally.
[server.api]
enabled = true
listen = "${API_ADDR}"
whitelist = ["127.0.0.1/32"]
read_only = true

# Anti-censorship / masking: unauthenticated traffic is transparently
# forwarded to the real site (mask_host defaults to tls_domain),
# so a scanner sees a genuine HTTPS host instead of a dead port.
[censorship]
tls_domain = "${MASK_DOMAIN}"

[access.users]
${PROXY_USERNAME} = "${secret}"
EOF
  chown "$PROXY_USER:$PROXY_USER" "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH"
  ok "Конфиг записан: $CONFIG_PATH (chmod 600)"
}

write_unit() {
  cat > "$UNIT_PATH" <<UNIT_EOF
[Unit]
Description=MTProto Proxy (telemt)
Documentation=https://github.com/telemt/telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PROXY_USER}
Group=${PROXY_USER}
WorkingDirectory=${PROXY_HOME}
ExecStart=${BIN_PATH} ${CONFIG_PATH}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

# Bind to privileged port without running as root
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictNamespaces=true
RestrictSUIDSGID=true
ReadWritePaths=${CONF_DIR} ${PROXY_HOME}

[Install]
WantedBy=multi-user.target
UNIT_EOF
  ok "systemd-юнит записан: $UNIT_PATH"
}

write_env() {
  umask 077
  cat > "$ENV_PATH" <<EOF
# State for mtproto-proxy-manager. Do not edit by hand unless you know what you do.
DEPLOY="${DEPLOY}"
SERVICE_NAME="${SERVICE_NAME}"
UNIT_PATH="${UNIT_PATH}"
CONF_DIR="${CONF_DIR}"
CONFIG_PATH="${CONFIG_PATH}"
LINKS_PATH="${LINKS_PATH}"
BACKUP_DIR="${BACKUP_DIR}"
BIN_PATH="${BIN_PATH}"
MANAGER_PATH="${MANAGER_PATH}"
PROXY_USER="${PROXY_USER}"
PROXY_HOME="${PROXY_HOME}"
PROXY_USERNAME="${PROXY_USERNAME}"
API_ADDR="${API_ADDR}"
PORT="${PORT}"
CONN_HOST="${CONN_HOST}"
MASK_DOMAIN="${MASK_DOMAIN}"
TELEMT_REPO="${TELEMT_REPO}"
TELEMT_VERSION="${TELEMT_VERSION}"
ARCH="${ARCH}"
LIBC="${LIBC}"
FW_BACKEND="${FW_BACKEND:-none}"
BBR_ENABLED="${BBR_ENABLED:-false}"
EOF
  chmod 600 "$ENV_PATH"
}

# ----------------------------------------------------------------------------
# Firewall
# ----------------------------------------------------------------------------
setup_firewall() {
  FW_BACKEND="none"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    FW_BACKEND="ufw"
    info "Обнаружен активный ufw — открываю ${PORT}/tcp."
    ufw allow "${PORT}/tcp" >/dev/null
    maybe_protect_ssh_ufw
    ok "ufw: разрешён ${PORT}/tcp."
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FW_BACKEND="firewalld"
    info "Обнаружен firewalld — открываю ${PORT}/tcp."
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld: разрешён ${PORT}/tcp."
  elif command -v iptables >/dev/null 2>&1; then
    FW_BACKEND="iptables"
    info "Добавляю ACCEPT-правило iptables для ${PORT}/tcp (без сброса существующих правил)."
    if ! iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT
    fi
    warn "Правило iptables может не сохраниться после перезагрузки — настройте netfilter-persistent при необходимости."
  else
    warn "Файрвол не обнаружен. Откройте ${PORT}/tcp вручную, если используете фильтрацию."
  fi
  export FW_BACKEND
}

maybe_protect_ssh_ufw() {
  local do_ssh="$PROTECT_SSH"
  if [ "$do_ssh" = "ask" ]; then
    if confirm "Защитить SSH-порт в ufw (allow OpenSSH), чтобы не потерять доступ?"; then do_ssh="true"; else do_ssh="false"; fi
  fi
  if [ "$do_ssh" = "true" ]; then
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
    ok "ufw: SSH разрешён."
  fi
}

# ----------------------------------------------------------------------------
# TCP BBR (performance only, NOT anti-DPI)
# ----------------------------------------------------------------------------
setup_bbr() {
  local want="$ENABLE_BBR"
  if [ "$want" = "ask" ]; then
    if confirm "Включить TCP BBR? (улучшает стабильность/скорость; это НЕ метод анти-DPI)"; then want="true"; else want="false"; fi
  fi
  BBR_ENABLED="false"
  [ "$want" = "true" ] || { info "BBR пропущен."; export BBR_ENABLED; return; }

  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    warn "Ядро не поддерживает BBR — пропускаю."
    export BBR_ENABLED; return
  fi
  cat > /etc/sysctl.d/99-mtproto-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
    BBR_ENABLED="true"; ok "TCP BBR включён."
  else
    warn "Не удалось активировать BBR."
  fi
  export BBR_ENABLED
}

# ----------------------------------------------------------------------------
# Service start + health checks
# ----------------------------------------------------------------------------
start_systemd() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
}

healthcheck() {
  local ok_active="false" ok_port="false"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then ok_active="true"; ok "Сервис активен."; else err "Сервис не активен."; fi
  if ss -lntH "sport = :${PORT}" 2>/dev/null | grep -q .; then ok_port="true"; ok "Порт ${PORT} слушается."; else err "Порт ${PORT} не слушается."; fi
  info "Последние строки журнала:"
  journalctl -u "$SERVICE_NAME" --no-pager -n 15 2>/dev/null | sed 's/^/    /' || true
  info "Проверка TLS-handshake на ${CONN_HOST}:${PORT} (ожидается ответ маскировочного сайта, не обрыв)..."
  if curl -k -sS -m 8 -o /dev/null -w "    HTTP %{http_code}, TLS %{ssl_verify_result}\n" "https://${CONN_HOST}:${PORT}/" 2>/dev/null; then
    ok "Соединение установилось (фронтинг отвечает)."
  else
    warn "curl не получил ответ — проверьте firewall/маскировочный домен. Это не всегда означает поломку."
  fi
  [ "$ok_active" = "true" ] && [ "$ok_port" = "true" ]
}

fetch_links() {
  local tries=15 out=""
  while [ "$tries" -gt 0 ]; do
    out="$(curl -fsS -m 5 "http://${API_ADDR}/v1/users" 2>/dev/null || true)"
    if [ -n "$out" ] && echo "$out" | jq -e '.data' >/dev/null 2>&1; then break; fi
    tries=$((tries-1)); sleep 1
  done
  if [ -z "$out" ]; then warn "Не удалось получить ссылки через Control API."; return 1; fi
  {
    echo "$out" | jq -r '
      .data[] |
      (.links.tls[]?     | "Link (Fake TLS / ee): \(.)"),
      (.links.secure[]?  | "Link (Secure / dd):   \(.)"),
      (.links.classic[]? | "Link (Classic):       \(.)")'
  } | tee "$LINKS_PATH" >/dev/null
  chmod 600 "$LINKS_PATH"; chown "$PROXY_USER:$PROXY_USER" "$LINKS_PATH" 2>/dev/null || true
}

print_summary() {
  local secret="$1"
  local masked="${secret:0:4}…${secret: -4}"
  echo
  echo "${C_BLD}========================================================${C_RST}"
  echo "${C_BLD} MTProto Proxy установлен.${C_RST}"
  echo "${C_BLD}========================================================${C_RST}"
  echo " Server:   ${CONN_HOST}"
  echo " Port:     ${PORT}"
  echo " Mode:     Fake TLS (ee) primary / Secure (dd) fallback"
  echo " SNI/mask: ${MASK_DOMAIN}"
  echo " Secret:   ${masked}  (полностью — через: mtproto-proxy-manager show-links)"
  echo " Status:   $(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
  echo
  if [ -s "$LINKS_PATH" ]; then
    sed 's/^/ /' "$LINKS_PATH"
  else
    echo " Ссылки: выполните  mtproto-proxy-manager show-links"
  fi
  echo "${C_BLD}========================================================${C_RST}"
  echo " Управление:  mtproto-proxy-manager <status|restart|logs|show-links|rotate-secret|update|uninstall>"
  echo
  warn "MTProto+FakeTLS СНИЖАЕТ обнаруживаемость DPI, но НЕ гарантирует обход. Это не замена VPN."
  echo
}

# ----------------------------------------------------------------------------
# Docker deployment (optional, isolation only — NOT a replacement for systemd)
# ----------------------------------------------------------------------------
deploy_docker() {
  local secret="$1"
  command -v docker >/dev/null 2>&1 || die "Docker не установлен. Установите Docker и docker compose, либо используйте режим systemd."
  docker compose version >/dev/null 2>&1 || die "Не найден 'docker compose' (v2)."

  write_config "$secret"   # reuse same config; telemt reads /etc/mtproto-proxy/telemt.toml
  cat > "${CONF_DIR}/docker-compose.yml" <<EOF
services:
  telemt:
    # Build from the official upstream source pinned to a tag (no third-party images).
    build:
      context: https://github.com/${TELEMT_REPO}.git#${TELEMT_VERSION}
    container_name: mtproto-proxy
    restart: unless-stopped
    read_only: true
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE"]
    ulimits:
      nofile: { soft: 65536, hard: 65536 }
    network_mode: host
    volumes:
      - ${CONFIG_PATH}:/app/config.toml:ro
EOF
  chmod 600 "${CONF_DIR}/docker-compose.yml"
  info "Сборка и запуск контейнера (может занять время — сборка из исходников Rust)..."
  ( cd "$CONF_DIR" && docker compose up -d --build )
  ok "Контейнер запущен."
}

# ----------------------------------------------------------------------------
# Manager installation (embedded)
# ----------------------------------------------------------------------------
install_manager() {
  cat > "$MANAGER_PATH" <<'MANAGER_EOF'
#!/usr/bin/env bash
# mtproto-proxy-manager — management tool for the telemt-based MTProto proxy.
set -euo pipefail

ENV_PATH="/etc/mtproto-proxy/installer.env"
[ -r "$ENV_PATH" ] || { echo "Не найден $ENV_PATH. Прокси не установлен?" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_PATH"

if [ -t 1 ]; then C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'; else C_G=""; C_Y=""; C_R=""; C_0=""; fi
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Требуются права root."; }

is_docker() { [ "${DEPLOY:-systemd}" = "docker" ]; }
dc() { ( cd "$CONF_DIR" && docker compose "$@" ); }

cmd_status() {
  if is_docker; then dc ps; else systemctl status "$SERVICE_NAME" --no-pager || true; fi
}
cmd_start()   { need_root; if is_docker; then dc up -d; else systemctl start "$SERVICE_NAME"; fi; ok "started"; }
cmd_stop()    { need_root; if is_docker; then dc down; else systemctl stop "$SERVICE_NAME"; fi; ok "stopped"; }
cmd_restart() { need_root; if is_docker; then dc restart || dc up -d; else systemctl restart "$SERVICE_NAME"; fi; ok "restarted"; }
cmd_logs() {
  if is_docker; then dc logs -f --tail=100; else journalctl -u "$SERVICE_NAME" -f -n 100; fi
}

cmd_show_links() {
  local out
  out="$(curl -fsS -m 5 "http://${API_ADDR}/v1/users" 2>/dev/null || true)"
  if [ -n "$out" ] && echo "$out" | jq -e '.data' >/dev/null 2>&1; then
    echo "$out" | jq -r '
      .data[] |
      (.links.tls[]?     | "Fake TLS (ee): \(.)"),
      (.links.secure[]?  | "Secure  (dd): \(.)"),
      (.links.classic[]? | "Classic:      \(.)")'
  elif [ -r "$LINKS_PATH" ]; then
    warn "Control API недоступен — показываю сохранённые ссылки."
    cat "$LINKS_PATH"
  else
    die "Ссылки недоступны: ни API, ни кэш."
  fi
}

cmd_rotate_secret() {
  need_root
  command -v openssl >/dev/null 2>&1 || die "openssl не найден."
  local new ts backup
  new="$(openssl rand -hex 16)"
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="${BACKUP_DIR}/telemt.toml.${ts}"
  install -d -m 0700 "$BACKUP_DIR"
  cp -a "$CONFIG_PATH" "$backup"
  chmod 600 "$backup"
  ok "Бэкап конфига: $backup"
  sed -i -E "s/^([[:space:]]*${PROXY_USERNAME}[[:space:]]*=[[:space:]]*\")[0-9a-fA-F]{32}(\".*)$/\1${new}\2/" "$CONFIG_PATH"
  grep -qE "\"${new}\"" "$CONFIG_PATH" || die "Не удалось обновить secret в конфиге (откатитесь к $backup)."
  cmd_restart
  sleep 2
  ok "Secret обновлён. Новые ссылки:"
  cmd_show_links
}

verify_and_install_binary() {
  # args: <version>  — downloads, verifies, installs into $BIN_PATH (systemd mode)
  local ver="$1"
  local asset="telemt-${ARCH}-linux-${LIBC}.tar.gz"
  local base="https://github.com/${TELEMT_REPO}/releases/download/${ver}"
  local url="${base}/${asset}"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  curl -fSL --retry 3 -o "${tmp}/${asset}" "$url" || die "Скачивание не удалось: $url"
  local computed expected=""
  computed="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
  if [ -n "${TELEMT_SHA256:-}" ]; then expected="$TELEMT_SHA256"
  elif curl -fsS -m 10 -o "${tmp}/s" "${url}.sha256" 2>/dev/null; then expected="$(grep -oE '[0-9a-fA-F]{64}' "${tmp}/s" | head -1 || true)"
  elif curl -fsS -m 10 -o "${tmp}/S" "${base}/SHA256SUMS" 2>/dev/null; then expected="$(grep "$asset" "${tmp}/S" | grep -oE '[0-9a-fA-F]{64}' | head -1 || true)"
  fi
  if [ -n "$expected" ]; then
    [ "${computed,,}" = "${expected,,}" ] || die "Контрольная сумма не совпала ($computed != $expected)."
    ok "Контрольная сумма подтверждена."
  elif [ "${ALLOW_UNVERIFIED:-false}" != "true" ]; then
    die "Нет опубликованной контрольной суммы. Перезапустите: TELEMT_SHA256=${computed} ... update  (или ALLOW_UNVERIFIED=true)."
  else
    warn "Установка без проверки целостности (ALLOW_UNVERIFIED=true)."
  fi
  tar -xzf "${tmp}/${asset}" -C "$tmp"
  local extracted; extracted="$(find "$tmp" -maxdepth 2 -type f -name telemt | head -1 || true)"
  [ -n "$extracted" ] || die "Бинарник не найден в архиве."
  install -m 0755 "$extracted" "$BIN_PATH"
}

cmd_update() {
  need_root
  local target="${1:-latest}" ver
  if [ "$target" = "latest" ]; then
    ver="$(curl -fsS "https://api.github.com/repos/${TELEMT_REPO}/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null || true)"
    [ -n "$ver" ] && [ "$ver" != "null" ] || die "Не удалось определить последнюю версию."
  else
    ver="$target"
  fi
  ok "Целевая версия: $ver"

  if is_docker; then
    cp -a "${CONF_DIR}/docker-compose.yml" "${BACKUP_DIR}/docker-compose.yml.$(date +%s)" 2>/dev/null || true
    sed -i -E "s/(#)[0-9A-Za-z._-]+\$/#${ver}/" "${CONF_DIR}/docker-compose.yml" 2>/dev/null || true
    dc up -d --build || die "Обновление контейнера не удалось."
    ok "Контейнер обновлён до ${ver}."
    return
  fi

  local bak
  bak="${BACKUP_DIR}/telemt.bin.$(date +%s)"
  install -d -m 0700 "$BACKUP_DIR"
  cp -a "$BIN_PATH" "$bak"
  if verify_and_install_binary "$ver"; then
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      ok "Обновлено до ${ver}. Старый бинарник: $bak"
    else
      warn "Сервис не поднялся — откат."
      cp -a "$bak" "$BIN_PATH"; systemctl restart "$SERVICE_NAME"
      die "Выполнен откат к предыдущей версии."
    fi
  fi
}

cmd_uninstall() {
  need_root
  echo "Будут удалены: сервис/контейнер, бинарник, файрвол-правило, этот manager."
  read -r -p "Продолжить удаление? [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]] || die "Отменено."

  if is_docker; then dc down 2>/dev/null || true
  else
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$UNIT_PATH"; systemctl daemon-reload 2>/dev/null || true
    rm -f "$BIN_PATH"
  fi

  case "${FW_BACKEND:-none}" in
    ufw)       ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true ;;
    firewalld) firewall-cmd --permanent --remove-port="${PORT}/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true ;;
    iptables)  iptables -D INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true ;;
  esac
  ok "Файрвол-правило для ${PORT}/tcp удалено (если было)."

  if [ "${BBR_ENABLED:-false}" = "true" ] && [ -f /etc/sysctl.d/99-mtproto-bbr.conf ]; then
    read -r -p "Удалить настройку BBR (/etc/sysctl.d/99-mtproto-bbr.conf)? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] && { rm -f /etc/sysctl.d/99-mtproto-bbr.conf; sysctl --system >/dev/null 2>&1 || true; ok "BBR-настройка удалена."; }
  fi

  read -r -p "Удалить конфиги в ${CONF_DIR} (включая секреты)? [y/N]: " a
  if [[ "$a" =~ ^[Yy]$ ]]; then rm -rf "$CONF_DIR"; ok "Конфиги удалены."; else warn "Конфиги сохранены в ${CONF_DIR}."; fi

  read -r -p "Удалить системного пользователя ${PROXY_USER}? [y/N]: " a
  [[ "$a" =~ ^[Yy]$ ]] && { userdel -r "$PROXY_USER" 2>/dev/null || true; ok "Пользователь удалён."; }

  rm -f "$MANAGER_PATH"
  ok "Удаление завершено."
}

usage() {
  cat <<USAGE
mtproto-proxy-manager — управление MTProto Proxy (telemt)

  status         состояние сервиса
  start          запустить
  stop           остановить
  restart        перезапустить
  logs           показать логи (follow)
  show-links     показать рабочие ссылки (ee/dd)
  rotate-secret  сгенерировать новый secret, бэкап, перезапуск
  update [ver]   обновить backend (по умолчанию latest), с проверкой и откатом
  uninstall      удалить прокси
USAGE
}

case "${1:-}" in
  status)         cmd_status ;;
  start)          cmd_start ;;
  stop)           cmd_stop ;;
  restart)        cmd_restart ;;
  logs)           cmd_logs ;;
  show-links)     cmd_show_links ;;
  rotate-secret)  cmd_rotate_secret ;;
  update)         shift; cmd_update "${1:-latest}" ;;
  uninstall)      cmd_uninstall ;;
  ""|-h|--help|help) usage ;;
  *) die "Неизвестная команда: $1 (см. --help)";;
esac
MANAGER_EOF
  chmod 755 "$MANAGER_PATH"
  ok "Установлен менеджер: $MANAGER_PATH"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  echo "${C_BLD}MTProto Proxy installer — Fake TLS (ee) / Secure (dd), backend: telemt${C_RST}"
  echo

  # crude flag parsing
  for arg in "$@"; do
    case "$arg" in
      --docker) DEPLOY="docker" ;;
      --systemd) DEPLOY="systemd" ;;
      --yes|-y) ASSUME_YES="true" ;;
      --bbr) ENABLE_BBR="true" ;;
      --no-bbr) ENABLE_BBR="false" ;;
      *) ;;
    esac
  done

  require_root
  detect_os
  detect_arch
  install_deps
  gather_config

  local secret; secret="$(gen_secret)"
  create_user_dirs

  if [ "$DEPLOY" = "docker" ]; then
    deploy_docker "$secret"
  else
    telemt_download_verify "$TELEMT_VERSION" "$BIN_PATH"
    write_config "$secret"
    write_unit
    setup_bbr
    setup_firewall
    start_systemd
    healthcheck || warn "Healthcheck выявил проблемы — см. логи: mtproto-proxy-manager logs"
  fi

  # firewall/bbr also for docker (host networking)
  if [ "$DEPLOY" = "docker" ]; then
    setup_bbr
    setup_firewall
  fi

  write_env
  install_manager
  fetch_links || true
  print_summary "$secret"
}

main "$@"
