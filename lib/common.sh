#!/usr/bin/env bash

PROJECT_VERSION="0.1.0"

ensure_dialog() {
  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installing dialog utilities"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail curl ca-certificates
  fi
}

yesno() {
  whiptail --title "$1" --yesno "$2" 12 72
}

msg() {
  whiptail --title "$1" --msgbox "$2" 14 78
}

input() {
  whiptail --title "$1" --inputbox "$2" 10 72 "${3:-}" 3>&1 1>&2 2>&3
}

password_input() {
  whiptail --title "$1" --passwordbox "$2" 10 72 3>&1 1>&2 2>&3
}

menu() {
  local title="$1"; shift
  local text="$1"; shift
  whiptail --title "$title" --menu "$text" 20 82 12 "$@" 3>&1 1>&2 2>&3
}

randpass() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28
}

get_next_ctid() {
  local id
  id="$(pvesh get /cluster/nextid 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    id=100
    while pct status "$id" >/dev/null 2>&1; do id=$((id+1)); done
  fi
  echo "$id"
}

validate_ipv4_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]
}

main_menu() {
  local mode
  mode="$(menu "Nextcloud Installer" "Choose installation mode:" \
    quick "Quick install (recommended)" \
    advanced "Advanced install" \
    exit "Exit")" || exit 0

  case "$mode" in
    quick) quick_install ;;
    advanced) advanced_install ;;
    *) exit 0 ;;
  esac
}
