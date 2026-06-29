#!/usr/bin/env bash
# install.sh — full production installer for Telegram MTProto proxy via mtg v2 FakeTLS
# Optional: AmneziaWG VPN access, UFW firewall, automatic updates, two-stage reboot flow.
set -Eeuo pipefail

wait_for_apt_locks() {
  local waited=0
  local max_wait="${APT_LOCK_TIMEOUT:-900}"
  local holders=""

  while true; do
    holders="$(
      {
        fuser /var/lib/dpkg/lock-frontend \
              /var/lib/dpkg/lock \
              /var/cache/apt/archives/lock \
              /var/lib/apt/lists/lock 2>/dev/null || true
      } | tr '\n' ' ' | xargs -r
    )"

    if [[ -z "$holders" ]]; then
      return 0
    fi

    if (( waited >= max_wait )); then
      warn "APT/dpkg lock is still held after ${max_wait}s. Lock holder PIDs: ${holders}"
      ps -fp ${holders} || true
      die "APT/dpkg lock timeout. Wait for real package operations to finish, then rerun the installer."
    fi

    warn "APT/dpkg lock is held; waiting 10s. Lock holder PIDs: ${holders}"
    ps -fp ${holders} || true
    sleep 10
    waited=$((waited + 10))
  done
}

apt_get_safe() {
  wait_for_apt_locks
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "$@"
}


readonly MTG_REPO="9seconds/mtg"
readonly BIN_PATH="/usr/local/bin/mtg"
readonly CTL_PATH="/usr/local/bin/mtgctl"
readonly CONFIG_PATH="/etc/mtg.toml"
readonly SERVICE_PATH="/etc/systemd/system/mtg.service"
readonly SERVICE_NAME="mtg"
readonly RUN_USER="mtg"
readonly RUN_GROUP="mtg"
readonly STATE_DIR="/var/lib/mtg-installer"
readonly PREPARED_MARKER="${STATE_DIR}/prepared.ok"
readonly SELF_PATH="${STATE_DIR}/install.sh"
readonly RESUME_SERVICE="/etc/systemd/system/mtg-installer-resume.service"
readonly RESUME_SCRIPT="${STATE_DIR}/resume.sh"
readonly MTG_UPDATE_SERVICE="/etc/systemd/system/mtg-auto-update.service"
readonly MTG_UPDATE_TIMER="/etc/systemd/system/mtg-auto-update.timer"
readonly AWG_CONFIG_DIR="/etc/amnezia/amneziawg"
readonly AWG_CONFIG_PATH="${AWG_CONFIG_DIR}/awg0.conf"
readonly AWG_CLIENT_DIR="/root/awg-clients"

ORIGINAL_ARGS=("$@")
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/shiirx-sudo/mtproto-proxy-installer/main}"
PORT="${PORT:-443}"
MASK_DOMAIN="${MASK_DOMAIN:-${DOMAIN:-}}"
RANDOM_MASK_DOMAIN=0
PIN_VERSION="${MTG_VERSION:-v2.2.8}"
ASSUME_YES=0
MODE="install"        # prepare | full | install | resume-install | update | uninstall
USE_LATEST=0
SKIP_CHECKSUM=0
AUTO_REBOOT=0
REMOVE_EXISTING=0
ENABLE_FIREWALL=0
AUTO_UPDATES=0
FULL_SYSTEM_UPGRADE=0
INSTALL_AWG=0
AWG_PORT="${AWG_PORT:-443}"
AWG_SUBNET="${AWG_SUBNET:-}"
AWG_CLIENT_NAME="${AWG_CLIENT_NAME:-admin}"
OS_ID=""
OS_PRETTY=""

MASK_DOMAIN_CANDIDATES=(
  "max.ru"
  "storage.yandex.net"
  "yastatic.net"
  "ya.ru"
  "vk.com"
  "api.vk.com"
  "userapi.com"
  "vkuservideo.ru"
  "cdnvideo.ru"
  "okcdn.ru"
  "hosting.reg.ru"
  "cdn.ngenix.net"
)

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[34m'; c_bld=$'\033[1m'
info()  { printf '%s[*]%s %s\n' "$c_blu" "$c_reset" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$c_yel" "$c_reset" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${c_bld}MTG v2 FakeTLS MTProto proxy installer${c_reset}

Recommended two-stage deployment:
  sudo ./install.sh --full --random-mask-domain --port 443 --install-awg --enable-firewall --auto-updates --auto-reboot --remove-existing --yes

If you do not want automatic reboot/resume:
  sudo ./install.sh --prepare --remove-existing --auto-updates --yes
  sudo reboot
  sudo ./install.sh --mask-domain ya.ru --port 443 --install-awg --enable-firewall --auto-updates --yes

Options:
  --prepare             Prepare dependencies, optionally remove old MTProto, then reboot/exit
  --full                Prepare first, then resume installation after reboot when --auto-reboot is set
  --resume-install      Internal mode used by reboot-resume service
  --mask-domain <host>  FakeTLS/SNI mask domain, e.g. ya.ru
  --domain <host>       Legacy alias for --mask-domain
  --random-mask-domain  Pick a random mask domain from the built-in list
  --port <port>         Public MTG TCP port, default 443
  --version <tag>       Pin mtg version, default ${PIN_VERSION}
  --latest              Resolve latest mtg release from GitHub API
  --skip-checksum       Allow install if checksum file is unavailable/mismatched lookup
  --install-awg         Install and configure AmneziaWG VPN access
  --awg-port <port>     AmneziaWG UDP port, default ${AWG_PORT}; can share number 443 with MTG/TCP
  --awg-subnet <CIDR>   AmneziaWG private subnet inside 10.0.0.0/8, e.g. 10.66.66.0/24
  --awg-client <name>   First AmneziaWG client config name, default ${AWG_CLIENT_NAME}
  --enable-firewall     Enable UFW: deny incoming; allow SSH, MTG TCP port, and AWG UDP port when enabled
  --auto-updates        Enable unattended system security updates + daily mtg update timer
  --full-system-upgrade Run apt-get full-upgrade during prepare phase. Optional; not default.
  --auto-reboot         In --prepare/--full mode: install resume service and reboot automatically
  --remove-existing     Remove known existing MTProto/MTG installs before installing
  -y, --yes             Non-interactive mode
  --update              Update only mtg binary, keep config
  --uninstall           Remove MTG service/binary/config/mtgctl and auto-update timer
  -h, --help            Show help

Environment variables: PORT, MASK_DOMAIN, DOMAIN, MTG_VERSION, AWG_PORT, AWG_SUBNET, AWG_CLIENT_NAME, REPO_RAW.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare) MODE="prepare"; shift ;;
    --full) MODE="full"; shift ;;
    --resume-install) MODE="resume-install"; shift ;;
    --mask-domain) MASK_DOMAIN="${2:?--mask-domain requires value}"; shift 2 ;;
    --domain) MASK_DOMAIN="${2:?--domain requires value}"; shift 2 ;;
    --port) PORT="${2:?--port requires value}"; shift 2 ;;
    --version) PIN_VERSION="${2:?--version requires value}"; shift 2 ;;
    --latest) USE_LATEST=1; shift ;;
    --skip-checksum) SKIP_CHECKSUM=1; shift ;;
    --install-awg) INSTALL_AWG=1; shift ;;
    --awg-port) AWG_PORT="${2:?--awg-port requires value}"; shift 2 ;;
    --awg-subnet) AWG_SUBNET="${2:?--awg-subnet requires value}"; shift 2 ;;
    --awg-client) AWG_CLIENT_NAME="${2:?--awg-client requires value}"; shift 2 ;;
    --random-mask-domain) RANDOM_MASK_DOMAIN=1; shift ;;
    --enable-firewall) ENABLE_FIREWALL=1; shift ;;
    --auto-updates) AUTO_UPDATES=1; shift ;;
    --full-system-upgrade) FULL_SYSTEM_UPGRADE=1; shift ;;
    --auto-reboot) AUTO_REBOOT=1; shift ;;
    --remove-existing) REMOVE_EXISTING=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --update) MODE="update"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo $0"; }
require_systemd() { command -v systemctl >/dev/null 2>&1 || die "systemd is required"; }

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  read -r -p "${prompt} [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

detect_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
  case "$OS_ID" in
    ubuntu|debian) ok "OS: ${OS_PRETTY}" ;;
    *) warn "OS '${OS_ID}' is not tested. Ubuntu/Debian expected." ;;
  esac
  require_systemd
}

validate_port_value() {
  local value="$1" name="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "${name} must be numeric"
  (( value >= 1 && value <= 65535 )) || die "${name} must be 1..65535"
}

validate_ports() {
  validate_port_value "$PORT" "MTG port"
  validate_port_value "$AWG_PORT" "AWG port"
}

detect_arch() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    i686|i386) echo "386" ;;
    *) die "Unsupported architecture: $m" ;;
  esac
}

apt_install_base_deps() {
  local deps=(ca-certificates curl tar coreutils iproute2 gawk sed grep findutils python3 openssl ufw fail2ban unattended-upgrades apt-listchanges)
  info "Installing base dependencies"
  apt_get_safe update -y
  apt_get_safe install -y "${deps[@]}"
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  timedatectl set-ntp true >/dev/null 2>&1 || true
}

ensure_deps() {
  local need=()
  for cmd in curl tar sha256sum ip awk sed grep find install; do
    command -v "$cmd" >/dev/null 2>&1 || case "$cmd" in
      sha256sum) need+=(coreutils) ;;
      ip) need+=(iproute2) ;;
      awk) need+=(gawk) ;;
      *) need+=("$cmd") ;;
    esac
  done
  if ! command -v python3 >/dev/null 2>&1; then need+=(python3); fi
  if ((${#need[@]})); then
    info "Installing dependencies: ${need[*]}"
    apt_get_safe update -y
    apt_get_safe install -y "${need[@]}"
  fi
}

setup_unattended_upgrades() {
  info "Enabling unattended system security updates"
  apt_get_safe install -y unattended-upgrades apt-listchanges
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat > /etc/apt/apt.conf.d/52mtg-auto-upgrades <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  ok "Unattended upgrades enabled; automatic reboot is disabled"
}

setup_mtg_auto_update_timer() {
  [[ "$AUTO_UPDATES" -eq 1 ]] || return 0
  if [[ ! -x "$CTL_PATH" ]]; then
    warn "mtgctl is not installed yet; mtg auto-update timer will be installed after mtgctl"
    return 0
  fi
  info "Installing mtg auto-update systemd timer"
  cat > "$MTG_UPDATE_SERVICE" <<EOF
[Unit]
Description=Update mtg binary to latest GitHub release with checksum verification
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${CTL_PATH} update --latest
EOF
  cat > "$MTG_UPDATE_TIMER" <<'EOF'
[Unit]
Description=Daily mtg update check

[Timer]
OnCalendar=03:30
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now mtg-auto-update.timer >/dev/null
  ok "mtg-auto-update.timer enabled"
}

prepare_system_packages() {
  if [[ "$FULL_SYSTEM_UPGRADE" -eq 1 ]]; then
    info "Running full system upgrade because --full-system-upgrade was set"
    apt_get_safe update -y
    apt_get_safe full-upgrade -y
  else
    info "Minimal prepare mode: updating package lists and installing required dependencies only"
    apt_get_safe update -y
  fi

  apt_install_base_deps

  if [[ "$INSTALL_AWG" -eq 1 ]]; then
    info "Installing current kernel headers for AmneziaWG"
    apt_get_safe install -y "linux-headers-$(uname -r)" || \
      warn "Could not install linux-headers-$(uname -r). AmneziaWG DKMS install may fail; consider --full-system-upgrade + reboot."
  fi

  if [[ "$AUTO_UPDATES" -eq 1 ]]; then setup_unattended_upgrades; fi
}

detect_existing_mtproto() {
  local out=()
  for svc in mtg mtproxy mtproto-proxy MTProxy mtproto_proxy; do
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service" || systemctl is-active --quiet "$svc" 2>/dev/null; then
      out+=("systemd:${svc}.service")
    fi
  done
  [[ -x /usr/local/bin/mtg ]] && out+=("file:/usr/local/bin/mtg")
  [[ -f /etc/mtg.toml ]] && out+=("file:/etc/mtg.toml")
  [[ -d /etc/mtproxy ]] && out+=("dir:/etc/mtproxy")
  [[ -d /etc/mtg ]] && out+=("dir:/etc/mtg")
  [[ -d /opt/MTProxy ]] && out+=("dir:/opt/MTProxy")
  if command -v docker >/dev/null 2>&1; then
    while IFS='|' read -r id image name; do
      [[ -z "$id" ]] && continue
      if [[ "$image" =~ (telegrammessenger/proxy|nineseconds/mtg) || "$name" =~ (mtproto|mtproxy|mtg-proxy) ]]; then
        out+=("docker:${name}:${image}")
      fi
    done < <(docker ps -a --format '{{.ID}}|{{.Image}}|{{.Names}}' 2>/dev/null || true)
  fi
  printf '%s\n' "${out[@]}"
}

remove_existing_mtproto() {
  info "Removing known existing MTProto/MTG installations"
  for svc in mtg mtproxy mtproto-proxy MTProxy mtproto_proxy; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  done
  rm -f /etc/systemd/system/mtg.service /etc/systemd/system/mtproxy.service /etc/systemd/system/mtproto-proxy.service
  systemctl daemon-reload || true
  if command -v docker >/dev/null 2>&1; then
    while IFS='|' read -r id image name; do
      [[ -z "$id" ]] && continue
      if [[ "$image" =~ (telegrammessenger/proxy|nineseconds/mtg) || "$name" =~ (mtproto|mtproxy|mtg-proxy) ]]; then
        warn "Removing Docker container ${name} (${image})"
        docker rm -f "$id" >/dev/null 2>&1 || true
      fi
    done < <(docker ps -a --format '{{.ID}}|{{.Image}}|{{.Names}}' 2>/dev/null || true)
  fi
  rm -f "$BIN_PATH" "$CTL_PATH" "$CONFIG_PATH"
  rm -rf /etc/mtproxy /etc/mtg
  if id -u "$RUN_USER" >/dev/null 2>&1; then userdel "$RUN_USER" >/dev/null 2>&1 || true; fi
  ok "Known MTProto/MTG files and services removed"
}

handle_existing_mtproto() {
  local findings
  findings="$(detect_existing_mtproto || true)"
  [[ -z "$findings" ]] && { ok "No existing MTProto/MTG install detected"; return 0; }
  warn "Existing MTProto/MTG installation detected:"
  printf '%s\n' "$findings" | sed 's/^/  - /' >&2
  if [[ "$REMOVE_EXISTING" -eq 1 ]]; then
    remove_existing_mtproto
    return 0
  fi
  if confirm "Remove detected MTProto/MTG installation before continuing?"; then
    remove_existing_mtproto
  else
    die "Refusing to install over existing MTProto/MTG. Re-run with --remove-existing or uninstall manually."
  fi
}

save_self_for_resume() {
  mkdir -p "$STATE_DIR"
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    cp "${BASH_SOURCE[0]}" "$SELF_PATH"
  else
    info "Current script is stdin; downloading install.sh from REPO_RAW for resume"
    curl -fsSL --retry 3 -o "$SELF_PATH" "${REPO_RAW}/install.sh" || die "Cannot save installer for resume. Run from a local file or set REPO_RAW."
  fi
  chmod 0755 "$SELF_PATH"
}

write_resume_service() {
  save_self_for_resume
  local args=(--resume-install)
  local skip_next=0
  for ((i=0; i<${#ORIGINAL_ARGS[@]}; i++)); do
    if [[ "$skip_next" -eq 1 ]]; then skip_next=0; continue; fi
    local a="${ORIGINAL_ARGS[$i]}"
    case "$a" in
      --prepare|--full|--auto-reboot|--resume-install) continue ;;
      --domain|--mask-domain|--port|--version|--awg-port|--awg-subnet|--awg-client)
        args+=("$a" "${ORIGINAL_ARGS[$((i+1))]:-}"); skip_next=1 ;;
      *) args+=("$a") ;;
    esac
  done
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf '/bin/bash %q' "$SELF_PATH"
    for a in "${args[@]}"; do printf ' %q' "$a"; done
    printf '\n'
    printf 'systemctl disable --now mtg-installer-resume.service >/dev/null 2>&1 || true\n'
    printf 'rm -f %q %q\n' "$RESUME_SERVICE" "$RESUME_SCRIPT"
    printf 'systemctl daemon-reload || true\n'
  } > "$RESUME_SCRIPT"
  chmod 0755 "$RESUME_SCRIPT"

  cat > "$RESUME_SERVICE" <<EOF
[Unit]
Description=Resume MTG installer after reboot
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${RESUME_SCRIPT}
StandardOutput=append:/var/log/mtg-installer-resume.log
StandardError=append:/var/log/mtg-installer-resume.log

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mtg-installer-resume.service >/dev/null
  ok "Resume service installed. Log after reboot: /var/log/mtg-installer-resume.log"
}

request_or_do_reboot() {
  touch "$PREPARED_MARKER"
  if [[ "$AUTO_REBOOT" -eq 1 ]]; then
    write_resume_service
    warn "Rebooting now. Installation will resume automatically after boot."
    systemctl reboot
    exit 0
  fi
  cat <<EOF

${c_yel}Preparation is complete.${c_reset}
Reboot the server, then run the installer again without --prepare:
  sudo reboot
  sudo ./install.sh --mask-domain ${MASK_DOMAIN:-ya.ru} --port ${PORT} --install-awg --enable-firewall --auto-updates --yes

EOF
  exit 0
}

resolve_version() {
  if [[ "$USE_LATEST" -eq 0 ]]; then
    echo "$PIN_VERSION"
    return
  fi
  local tag
  tag="$(curl -fsSL "https://api.github.com/repos/${MTG_REPO}/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name":[[:space:]]*"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"([^"]+)"$/\1/')" || true
  [[ -n "$tag" ]] || die "Cannot resolve latest version. Use --version v2.2.8"
  echo "$tag"
}

download_and_install_binary() {
  local tag="$1" arch="$2"
  local ver="${tag#v}"
  local asset="mtg-${ver}-linux-${arch}.tar.gz"
  local sums="mtg-${ver}-checksums.txt"
  local base="https://github.com/${MTG_REPO}/releases/download/${tag}"
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  info "Downloading ${asset} (${tag})"
  curl -fSL --retry 3 --retry-delay 2 -o "${tmp}/${asset}" "${base}/${asset}" \
    || die "Cannot download ${asset}. Check version/architecture/network."

  info "Downloading checksums and verifying sha256"
  if curl -fSL --retry 3 -o "${tmp}/${sums}" "${base}/${sums}" 2>/dev/null; then
    local expected actual
    expected="$(awk -v a="$asset" '$2 == a {print $1; exit}' "${tmp}/${sums}")"
    if [[ -z "$expected" ]]; then
      if [[ "$SKIP_CHECKSUM" -eq 1 ]]; then
        warn "No checksum entry for ${asset}; continuing because --skip-checksum was set."
      else
        die "Checksum file does not contain ${asset}. Refusing to install. Use --skip-checksum only if you accept the risk."
      fi
    else
      actual="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
      [[ "$expected" == "$actual" ]] || die "SHA256 mismatch for ${asset}. Refusing to install."
      ok "sha256 verified"
    fi
  else
    if [[ "$SKIP_CHECKSUM" -eq 1 ]]; then
      warn "Checksum file unavailable; continuing because --skip-checksum was set."
    else
      die "Checksum file unavailable. Refusing to install. Use --skip-checksum only if you accept the risk."
    fi
  fi

  info "Installing binary into ${BIN_PATH}"
  tar -xzf "${tmp}/${asset}" -C "$tmp"
  local found; found="$(find "$tmp" -type f -name mtg -perm /111 | head -1)"
  [[ -n "$found" ]] || die "mtg binary not found in archive"
  install -m 0755 "$found" "$BIN_PATH"
  ok "Installed: $("$BIN_PATH" --version 2>/dev/null | head -1 || echo "$tag")"
}

random_mask_domain() {
  local n idx
  n="${#MASK_DOMAIN_CANDIDATES[@]}"
  idx="$(rand_int 0 $((n - 1)))"
  echo "${MASK_DOMAIN_CANDIDATES[$idx]}"
}

show_mask_domain_candidates() {
  local i=1 d
  for d in "${MASK_DOMAIN_CANDIDATES[@]}"; do
    printf '  %2d) %s\n' "$i" "$d"
    i=$((i + 1))
  done
}

prompt_mask_domain() {
  if [[ "$RANDOM_MASK_DOMAIN" -eq 1 ]]; then
    MASK_DOMAIN="$(random_mask_domain)"
    ok "Random mask domain selected: ${MASK_DOMAIN}"
    return
  fi
  [[ -n "$MASK_DOMAIN" ]] && return

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    MASK_DOMAIN="$(random_mask_domain)"
    ok "No --mask-domain provided in --yes mode; random mask domain selected: ${MASK_DOMAIN}"
    return
  fi

  cat <<EOF

${c_bld}FakeTLS mask domain / SNI${c_reset}
Choose a real HTTPS domain that makes sense for your VPS/network.
Bad example: google.com on a non-Google VPS.
Better: provider-related domain, CDN/provider domain, or your own HTTPS domain.

Options:
  1) Enter my own domain
  2) Pick random from built-in list
  3) Show built-in list and choose by number
EOF
  local choice
  read -rp "Choice [2]: " choice
  choice="${choice:-2}"
  case "$choice" in
    1)
      read -rp "Mask domain: " MASK_DOMAIN
      ;;
    3)
      show_mask_domain_candidates
      local idx
      read -rp "Number [1]: " idx
      idx="${idx:-1}"
      [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#MASK_DOMAIN_CANDIDATES[@]} )) || die "Invalid domain list number"
      MASK_DOMAIN="${MASK_DOMAIN_CANDIDATES[$((idx - 1))]}"
      ;;
    2|*)
      MASK_DOMAIN="$(random_mask_domain)"
      ok "Random mask domain selected: ${MASK_DOMAIN}"
      ;;
  esac
}

validate_mask_domain() {
  [[ "$MASK_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Invalid mask domain: ${MASK_DOMAIN}"
}

detect_prefer_ip() {
  if ip -6 route show default 2>/dev/null | grep -q .; then
    echo "prefer-ipv6"
  else
    echo "prefer-ipv4"
  fi
}

ensure_runtime_user() {
  if ! getent group "$RUN_GROUP" >/dev/null; then
    groupadd --system "$RUN_GROUP"
  fi
  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$RUN_GROUP" "$RUN_USER"
  fi
}

check_port_free() {
  if command -v ss >/dev/null 2>&1 && ss -ltnH "( sport = :${PORT} )" 2>/dev/null | grep -q .; then
    die "TCP port ${PORT} is already in use. Stop conflicting service or choose --port 8443."
  fi
}

write_config() {
  local secret prefer
  info "Generating FakeTLS secret for mask domain ${MASK_DOMAIN}"
  secret="$("$BIN_PATH" generate-secret --hex "$MASK_DOMAIN")" || die "mtg failed to generate secret"
  [[ "$secret" =~ ^ee[0-9a-f]+$ ]] || die "Generated secret does not look like FakeTLS hex secret"
  prefer="$(detect_prefer_ip)"

  info "Writing ${CONFIG_PATH}"
  umask 027
  cat > "$CONFIG_PATH" <<EOF
# mtg config generated by install.sh on $(date -u +%FT%TZ)
secret = "${secret}"
bind-to = "0.0.0.0:${PORT}"
prefer-ip = "${prefer}"
EOF
  chown root:"$RUN_GROUP" "$CONFIG_PATH"
  chmod 0640 "$CONFIG_PATH"
  ok "Config written: ${CONFIG_PATH} (root:${RUN_GROUP} 0640)"
}

install_service() {
  info "Installing systemd service"
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=mtg - MTProto proxy server
Documentation=https://github.com/9seconds/mtg
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
ExecStart=${BIN_PATH} run ${CONFIG_PATH}
Restart=always
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  sleep 1
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Service ${SERVICE_NAME} is active"
  else
    warn "Service is not active. Check: journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
  fi
}

install_mtgctl() {
  info "Installing mtgctl"
  local script_dir src
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  src="${script_dir}/mtgctl"
  if [[ -f "$src" ]]; then
    install -m 0755 "$src" "$CTL_PATH"
    ok "mtgctl installed from local repository"
    return
  fi
  if curl -fsSL --retry 2 -o "$CTL_PATH" "${REPO_RAW}/mtgctl" 2>/dev/null && [[ -s "$CTL_PATH" ]]; then
    chmod 0755 "$CTL_PATH"
    ok "mtgctl installed from ${REPO_RAW}"
  else
    warn "Cannot install mtgctl from local file or REPO_RAW. Proxy is installed; mtgctl is optional."
    rm -f "$CTL_PATH"
  fi
}

public_ip() {
  curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}'
}

get_secret() { grep -E '^secret' "$CONFIG_PATH" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'; }

show_access() {
  local ip secret
  ip="$(public_ip)"; ip="${ip:-<SERVER_IP>}"
  secret="$(get_secret)"
  printf '\n%s════════════ MTG proxy ready ════════════%s\n' "$c_grn" "$c_reset"
  printf 'Server: %s\nPort:   %s/tcp\nMask domain: %s\n\n' "$ip" "$PORT" "$MASK_DOMAIN"
  printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$ip" "$PORT" "$secret"
  printf 'https://t.me/proxy?server=%s&port=%s&secret=%s\n\n' "$ip" "$PORT" "$secret"
  info "Diagnostics: mtg doctor"
  "$BIN_PATH" doctor "$CONFIG_PATH" 2>&1 | sed 's/^/    /' || warn "doctor reported warnings/errors"
}

rand_int() {
  local min="$1" max="$2" n
  n="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
  echo $(( min + n % (max - min + 1) ))
}

unique_h_values() {
  local vals=() v exists
  while ((${#vals[@]} < 4)); do
    v="$(rand_int 5 2147483647)"
    exists=0
    for x in "${vals[@]}"; do [[ "$x" == "$v" ]] && exists=1; done
    [[ "$exists" -eq 0 ]] && vals+=("$v")
  done
  printf '%s %s %s %s\n' "${vals[@]}"
}

default_iface() { ip -4 route list default 2>/dev/null | awk '{print $5; exit}'; }

random_awg_subnet() {
  # Random /24 inside 10.0.0.0/8, avoiding 10.0.0.0/24 and 10.255.255.0/24.
  printf '10.%s.%s.0/24\n' "$(rand_int 1 254)" "$(rand_int 0 255)"
}

select_awg_subnet() {
  [[ "$INSTALL_AWG" -eq 1 ]] || return 0
  if [[ -n "$AWG_SUBNET" ]]; then
    validate_awg_subnet
    return
  fi
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    AWG_SUBNET="$(random_awg_subnet)"
    ok "No --awg-subnet provided in --yes mode; random AWG subnet selected: ${AWG_SUBNET}"
    return
  fi
  cat <<EOF

${c_bld}AmneziaWG private subnet${c_reset}
You can specify a subnet inside 10.0.0.0/8, or let the installer pick a random /24.
Example: 10.66.66.0/24
EOF
  local choice
  read -rp "Use random subnet? [Y/n]: " choice
  if [[ -z "$choice" || "$choice" =~ ^[Yy]$ ]]; then
    AWG_SUBNET="$(random_awg_subnet)"
    ok "Random AWG subnet selected: ${AWG_SUBNET}"
  else
    read -rp "AWG subnet CIDR: " AWG_SUBNET
  fi
  validate_awg_subnet
}

validate_awg_subnet() {
  python3 - "$AWG_SUBNET" <<'PY'
import sys, ipaddress
raw = sys.argv[1]
try:
    net = ipaddress.ip_network(raw, strict=False)
except Exception as e:
    raise SystemExit(f"Invalid AWG subnet: {raw}: {e}")
if net.version != 4:
    raise SystemExit("AWG subnet must be IPv4")
if not net.subnet_of(ipaddress.ip_network("10.0.0.0/8")):
    raise SystemExit("AWG subnet must be inside 10.0.0.0/8")
if net.prefixlen > 30:
    raise SystemExit("AWG subnet must have at least two usable host addresses; /30 or larger is required")
# valid
PY
}

awg_addresses() {
  python3 - "$AWG_SUBNET" <<'PY'
import sys, ipaddress
net = ipaddress.ip_network(sys.argv[1], strict=False)
server = ipaddress.IPv4Address(int(net.network_address) + 1)
client = ipaddress.IPv4Address(int(net.network_address) + 2)
if server not in net or client not in net:
    raise SystemExit("AWG subnet is too small")
print(net.with_prefixlen, f"{server}/{net.prefixlen}", f"{client}/32", str(client))
PY
}

install_amneziawg() {
  [[ "$INSTALL_AWG" -eq 1 ]] || return 0
  [[ "$OS_ID" == "ubuntu" ]] || die "Automatic AmneziaWG installation uses official Ubuntu PPA and currently requires Ubuntu."
  validate_port_value "$AWG_PORT" "AWG port"
  select_awg_subnet

  info "Installing AmneziaWG packages from official PPA"
  apt_get_safe install -y software-properties-common python3-launchpadlib gnupg2 dkms "linux-headers-$(uname -r)" iptables qrencode
  add-apt-repository -y ppa:amnezia/ppa
  add-apt-repository -y --enable-source ppa:amnezia/ppa >/dev/null 2>&1 || true
  apt_get_safe update -y
  apt_get_safe install -y amneziawg
  command -v awg >/dev/null 2>&1 || die "awg command not found after amneziawg install"

  modprobe amneziawg >/dev/null 2>&1 || warn "modprobe amneziawg failed; DKMS may require reboot or kernel headers."

  mkdir -p "$AWG_CONFIG_DIR" /etc/wireguard "$AWG_CLIENT_DIR"
  chmod 700 "$AWG_CONFIG_DIR" "$AWG_CLIENT_DIR"

  local server_priv server_pub client_priv client_pub psk iface ip awg_net awg_server_cidr awg_client_cidr awg_client_ip
  server_priv="$(awg genkey)"; server_pub="$(printf '%s' "$server_priv" | awg pubkey)"
  client_priv="$(awg genkey)"; client_pub="$(printf '%s' "$client_priv" | awg pubkey)"
  psk="$(awg genpsk 2>/dev/null || openssl rand -base64 32)"
  iface="$(default_iface)"; iface="${iface:-eth0}"
  ip="$(public_ip)"; ip="${ip:-<SERVER_IP>}"
  read -r awg_net awg_server_cidr awg_client_cidr awg_client_ip < <(awg_addresses)

  local jc jmin jmax s1 s2 h1 h2 h3 h4
  jc="$(rand_int 4 10)"; jmin="$(rand_int 64 128)"; jmax="$(rand_int 256 1024)"
  s1="$(rand_int 15 64)"; s2="$(rand_int 15 64)"
  read -r h1 h2 h3 h4 < <(unique_h_values)

  cat > "$AWG_CONFIG_PATH" <<EOF
[Interface]
Address = ${awg_server_cidr}
ListenPort = ${AWG_PORT}
PrivateKey = ${server_priv}
Jc = ${jc}
Jmin = ${jmin}
Jmax = ${jmax}
S1 = ${s1}
S2 = ${s2}
H1 = ${h1}
H2 = ${h2}
H3 = ${h3}
H4 = ${h4}
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${iface} -j MASQUERADE

[Peer]
PublicKey = ${client_pub}
PresharedKey = ${psk}
AllowedIPs = ${awg_client_cidr}
EOF
  chmod 600 "$AWG_CONFIG_PATH"
  ln -sf "$AWG_CONFIG_PATH" /etc/wireguard/awg0.conf

  local client_conf="${AWG_CLIENT_DIR}/${AWG_CLIENT_NAME}.conf"
  cat > "$client_conf" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = ${awg_client_cidr}
DNS = 1.1.1.1, 8.8.8.8
Jc = ${jc}
Jmin = ${jmin}
Jmax = ${jmax}
S1 = ${s1}
S2 = ${s2}
H1 = ${h1}
H2 = ${h2}
H3 = ${h3}
H4 = ${h4}

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${ip}:${AWG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$client_conf"

  cat > /etc/sysctl.d/99-awg-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null 2>&1 || true

  systemctl enable --now awg-quick@awg0 >/dev/null 2>&1 || {
    warn "awg-quick@awg0 failed to start. Check: journalctl -u awg-quick@awg0 -n 80 --no-pager"
    return 0
  }
  ok "AmneziaWG is active on UDP ${AWG_PORT}; subnet ${awg_net}; client config: ${client_conf}"
  if command -v qrencode >/dev/null 2>&1; then
    printf '\n%sAmneziaWG client QR (%s):%s\n' "$c_grn" "$client_conf" "$c_reset"
    qrencode -t ANSIUTF8 < "$client_conf" || true
  fi
}

ssh_port() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}'
  fi
}

configure_firewall() {
  [[ "$ENABLE_FIREWALL" -eq 1 ]] || { warn "Firewall was not enabled. Re-run with --enable-firewall if needed."; return 0; }
  command -v ufw >/dev/null 2>&1 || apt_get_safe install -y ufw
  local sp; sp="$(ssh_port)"; sp="${sp:-22}"
  info "Configuring UFW: allow SSH ${sp}/tcp, MTG ${PORT}/tcp$( [[ "$INSTALL_AWG" -eq 1 ]] && printf ', AWG %s/udp' "$AWG_PORT" )"
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${sp}/tcp" comment 'SSH'
  ufw allow "${PORT}/tcp" comment 'MTG MTProto TCP'
  if [[ "$INSTALL_AWG" -eq 1 ]]; then
    ufw allow "${AWG_PORT}/udp" comment 'AmneziaWG UDP'
  fi
  ufw --force enable
  ufw status verbose
}

do_prepare() {
  require_root; detect_os; validate_ports
  mkdir -p "$STATE_DIR"
  handle_existing_mtproto
  prepare_system_packages
  ok "Prepare phase completed"
  request_or_do_reboot
}

do_uninstall() {
  require_root
  info "Uninstalling MTG proxy"
  local old_port=""
  [[ -f "$CONFIG_PATH" ]] && old_port="$(grep -E '^bind-to' "$CONFIG_PATH" | sed -E 's/.*:([0-9]+).*/\1/' || true)"
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable --now mtg-auto-update.timer >/dev/null 2>&1 || true
  rm -f "$SERVICE_PATH" "$MTG_UPDATE_SERVICE" "$MTG_UPDATE_TIMER"
  systemctl daemon-reload || true
  if [[ -n "$old_port" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
  fi
  rm -f "$BIN_PATH" "$CONFIG_PATH" "$CTL_PATH"
  if id -u "$RUN_USER" >/dev/null 2>&1; then userdel "$RUN_USER" >/dev/null 2>&1 || true; fi
  ok "Removed MTG service, binary, config, mtgctl and auto-update timer. AWG is left untouched."
}

do_update() {
  require_root; detect_os; ensure_deps
  local arch tag; arch="$(detect_arch)"; tag="$(resolve_version)"
  download_and_install_binary "$tag" "$arch"
  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl restart "$SERVICE_NAME"
    ok "Service restarted"
  fi
}

do_install() {
  require_root; detect_os; validate_ports; ensure_deps
  if [[ "$MODE" != "resume-install" && ! -f "$PREPARED_MARKER" ]]; then
    warn "Prepare marker not found. Recommended: run --prepare and reboot before installation."
    if [[ "$ASSUME_YES" -eq 0 ]] && confirm "Run prepare phase now?"; then do_prepare; fi
  fi
  handle_existing_mtproto
  local arch tag; arch="$(detect_arch)"; tag="$(resolve_version)"
  ok "Target: linux-${arch}; mtg version: ${tag}"
  prompt_mask_domain; validate_mask_domain
  check_port_free
  download_and_install_binary "$tag" "$arch"
  ensure_runtime_user
  write_config
  install_service
  install_mtgctl
  install_amneziawg
  configure_firewall
  setup_mtg_auto_update_timer
  show_access
}

case "$MODE" in
  prepare) do_prepare ;;
  full) do_prepare ;;
  resume-install|install) do_install ;;
  update) do_update ;;
  uninstall) do_uninstall ;;
  *) die "Invalid mode: $MODE" ;;
esac
