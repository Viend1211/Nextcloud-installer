#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="Nextcloud Installer for Proxmox"
VERSION="0.3.0"
REPO_RAW="https://raw.githubusercontent.com/Viend1211/Nextcloud-installer/main"
WORKDIR="/tmp/nextcloud-installer"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

die(){ echo "${RED}ERROR:${NC} $*" >&2; exit 1; }
info(){ echo -e "\n${BLUE}==>${NC} $*"; }
ok(){ echo -e "${GREEN}OK:${NC} $*"; }
warn(){ echo -e "${YELLOW}WARNING:${NC} $*"; }

[[ $EUID -eq 0 ]] || die "Run this installer as root on the Proxmox VE host."
command -v pveversion >/dev/null 2>&1 || die "Proxmox VE was not detected."

echo "============================================================"
echo " $PROJECT v$VERSION"
echo "============================================================"
pveversion || true
echo

mkdir -p "$WORKDIR/lib" "$WORKDIR/templates"

download() {
  local src="$1" dst="$2"
  curl -fsSL --retry 4 --retry-delay 2 "$src" -o "$dst"
}

# install.sh can work when launched directly from GitHub.
for f in common.sh repos.sh storage.sh lxc.sh nextcloud.sh admin.sh; do
  download "$REPO_RAW/lib/$f" "$WORKDIR/lib/$f"
done
download "$REPO_RAW/templates/nginx.conf" "$WORKDIR/templates/nginx.conf"
mkdir -p "$WORKDIR/maintenance"
download "$REPO_RAW/maintenance/storage-migrator.sh" "$WORKDIR/maintenance/storage-migrator.sh"
chmod +x "$WORKDIR/maintenance/storage-migrator.sh"

# shellcheck source=/dev/null
source "$WORKDIR/lib/common.sh"
source "$WORKDIR/lib/repos.sh"
source "$WORKDIR/lib/storage.sh"
source "$WORKDIR/lib/lxc.sh"
source "$WORKDIR/lib/nextcloud.sh"
source "$WORKDIR/lib/admin.sh"

init_logging
ensure_dialog
fix_proxmox_repositories_if_needed

existing_installation_menu() {
  while true; do
    local action
    action="$(menu "Existing installation" "Manage an existing Nextcloud/LXC:" \
      storage "Storage & disks: add, replace, RAID1, expand, upgrade advisor" \
      nextcloud "Nextcloud administration" \
      container "LXC administration" \
      diagnostics "Diagnostics" \
      back "Back")" || return 0

    case "$action" in
      storage) bash "$WORKDIR/maintenance/storage-migrator.sh" ;;
      nextcloud) admin_nextcloud_occ ;;
      container) admin_container_tools ;;
      diagnostics) admin_diagnostics ;;
      *) return 0 ;;
    esac
  done
}

while true; do
  action="$(menu "Nextcloud for Proxmox v$VERSION" "Choose mode:" \
    install "Install a new Nextcloud" \
    manage "Manage existing installation" \
    diagnostics "Proxmox / storage diagnostics" \
    exit "Exit")" || exit 0

  case "$action" in
    install) main_menu; exit 0 ;;
    manage) existing_installation_menu ;;
    diagnostics) admin_diagnostics ;;
    *) exit 0 ;;
  esac
done
