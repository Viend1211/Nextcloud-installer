#!/usr/bin/env bash

PROJECT_VERSION="0.1.3"

LOG_FILE="/var/log/nextcloud-installer.log"
CURRENT_STEP="Startup"
STEP_NO=0
TOTAL_STEPS=10

init_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"

  {
    echo
    echo "============================================================"
    echo "Nextcloud Installer v$PROJECT_VERSION"
    echo "Started: $(date -Is)"
    echo "Host: $(hostname)"
    echo "============================================================"
  } >> "$LOG_FILE"
}

progress_header() {
  clear || true
  echo "============================================================"
  echo " Nextcloud Installer for Proxmox v$PROJECT_VERSION"
  echo "============================================================"
  echo
  echo " Full log: $LOG_FILE"
  echo
}

step() {
  STEP_NO=$((STEP_NO + 1))
  CURRENT_STEP="$1"

  echo
  echo "------------------------------------------------------------"
  printf '[%02d/%02d] %s\n' "$STEP_NO" "$TOTAL_STEPS" "$CURRENT_STEP"
  echo "------------------------------------------------------------"

  {
    echo
    echo "[$(date -Is)] STEP $STEP_NO/$TOTAL_STEPS: $CURRENT_STEP"
  } >> "$LOG_FILE"
}

log_cmd() {
  # Run a command while showing its live output and appending everything
  # to the installer log.
  "$@" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  return "$rc"
}

log_text() {
  echo "$*" | tee -a "$LOG_FILE"
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  local cmd="${BASH_COMMAND:-unknown}"

  set +e
  echo
  echo "============================================================"
  echo " INSTALLATION FAILED"
  echo "============================================================"
  echo " Step:    $CURRENT_STEP"
  echo " Exit:    $rc"
  echo " Line:    $line"
  echo " Command: $cmd"
  echo " Log:     $LOG_FILE"
  echo
  echo " Last 40 log lines:"
  echo "------------------------------------------------------------"
  tail -n 40 "$LOG_FILE" 2>/dev/null || true
  echo "------------------------------------------------------------"
  echo
  echo "Nothing else will be changed automatically after this error."
  echo "You can inspect the complete log with:"
  echo "  less $LOG_FILE"
  echo
  exit "$rc"
}

trap on_error ERR

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
