#!/usr/bin/env bash
set -Eeuo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/shiirx-sudo/mtproto-proxy-installer/main}"
INSTALLER_PATH="${INSTALLER_PATH:-/root/mtg-install.sh}"

MTG_PORT="${MTG_PORT:-443}"
AWG_PORT="${AWG_PORT:-443}"
MASK_DOMAIN="${MASK_DOMAIN:-}"
AWG_SUBNET="${AWG_SUBNET:-}"

INSTALL_AWG="${INSTALL_AWG:-1}"
ENABLE_FIREWALL="${ENABLE_FIREWALL:-1}"
AUTO_REBOOT="${AUTO_REBOOT:-1}"
AUTO_UPDATES="${AUTO_UPDATES:-1}"
REMOVE_EXISTING="${REMOVE_EXISTING:-1}"
FULL_SYSTEM_UPGRADE="${FULL_SYSTEM_UPGRADE:-0}"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  sudo bash quick-install.sh [options]

Options:
  --mask-domain DOMAIN      Use specific MTG FakeTLS mask domain
  --random-mask-domain      Use random domain from built-in list (default)
  --port PORT               MTG TCP port, default: 443
  --awg-port PORT           AmneziaWG UDP port, default: 443
  --awg-subnet CIDR         AmneziaWG subnet, e.g. 10.66.66.0/24
  --no-awg                  Do not install AmneziaWG
  --no-firewall             Do not enable UFW
  --no-reboot               Do not auto-reboot after preparation
  --no-auto-updates         Do not configure automatic updates
  --full-system-upgrade     Run apt-get full-upgrade before installation (not default)
  --keep-existing           Do not remove existing MTProto/MTG installs
  -h, --help                Show help

Environment variables are also supported:
  MASK_DOMAIN=ya.ru AWG_SUBNET=10.66.66.0/24 sudo bash quick-install.sh
EOF
}

RANDOM_MASK_DOMAIN=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mask-domain)
      MASK_DOMAIN="${2:-}"; RANDOM_MASK_DOMAIN=0; shift 2 ;;
    --random-mask-domain)
      MASK_DOMAIN=""; RANDOM_MASK_DOMAIN=1; shift ;;
    --port)
      MTG_PORT="${2:-}"; shift 2 ;;
    --awg-port)
      AWG_PORT="${2:-}"; shift 2 ;;
    --awg-subnet)
      AWG_SUBNET="${2:-}"; shift 2 ;;
    --no-awg)
      INSTALL_AWG=0; shift ;;
    --no-firewall)
      ENABLE_FIREWALL=0; shift ;;
    --no-reboot)
      AUTO_REBOOT=0; shift ;;
    --no-auto-updates)
      AUTO_UPDATES=0; shift ;;
    --keep-existing)
      REMOVE_EXISTING=0; shift ;;
    --full-system-upgrade)
      FULL_SYSTEM_UPGRADE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run as root: curl -fsSL ${RAW_BASE}/quick-install.sh | sudo bash"

log "Downloading installer to ${INSTALLER_PATH}"
curl -fsSL "${RAW_BASE}/install.sh" -o "${INSTALLER_PATH}"
chmod +x "${INSTALLER_PATH}"

args=(--full --port "${MTG_PORT}" --yes)

if [[ -n "${MASK_DOMAIN}" ]]; then
  args+=(--mask-domain "${MASK_DOMAIN}")
elif [[ "${RANDOM_MASK_DOMAIN}" == "1" ]]; then
  args+=(--random-mask-domain)
fi

if [[ "${INSTALL_AWG}" == "1" ]]; then
  args+=(--install-awg --awg-port "${AWG_PORT}")
  if [[ -n "${AWG_SUBNET}" ]]; then
    args+=(--awg-subnet "${AWG_SUBNET}")
  fi
fi

if [[ "${ENABLE_FIREWALL}" == "1" ]]; then
  args+=(--enable-firewall)
fi

if [[ "${AUTO_UPDATES}" == "1" ]]; then
  args+=(--auto-updates)
fi

if [[ "${AUTO_REBOOT}" == "1" ]]; then
  args+=(--auto-reboot)
fi

if [[ "${REMOVE_EXISTING}" == "1" ]]; then
  args+=(--remove-existing)
fi

if [[ "${FULL_SYSTEM_UPGRADE}" == "1" ]]; then
  args+=(--full-system-upgrade)
fi

log "Running installer:"
printf '  %q' "${INSTALLER_PATH}" "${args[@]}"
printf '\n'

exec "${INSTALLER_PATH}" "${args[@]}"
