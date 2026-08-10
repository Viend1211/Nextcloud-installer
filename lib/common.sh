#!/usr/bin/env bash

PROJECT_VERSION="0.4.0"

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
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail curl ca-certificates openssl
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
  # Avoid `tr | head` here: with `set -o pipefail` the producer receives
  # SIGPIPE when head exits, which becomes exit code 141 and aborts install.
  # openssl outputs a fixed amount of random data without a truncating pipe.
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    # 16 random bytes -> 32 hex chars, no pipeline/SIGPIPE involved.
    od -An -N16 -tx1 /dev/urandom | sed 's/[[:space:]]//g'
  fi
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

detect_public_ipv4() {
  local ip=""
  local url

  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    ip="$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '\r\n ' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

choose_remote_access() {
  REMOTE_MODE="$(menu "Удалённый доступ" \
    "Выберите вариант внешнего доступа:" \
    local "Только локальная сеть" \
    public "Автоматически определить внешний IPv4" \
    custom "Добавить домен или IP вручную")"

  PUBLIC_IP=""
  CUSTOM_REMOTE_HOST=""

  case "$REMOTE_MODE" in
    local)
      ;;
    public)
      PUBLIC_IP="$(detect_public_ipv4 || true)"
      if [[ -z "$PUBLIC_IP" ]]; then
        msg "Public IP" "The installer could not automatically detect a public IPv4 address.

You can continue and add it later."
        REMOTE_MODE="local"
      else
        if ! yesno "Обнаружен внешний IP" \
"Detected public IPv4:

$PUBLIC_IP

Add it to Nextcloud trusted_domains?

This does NOT configure router port forwarding or HTTPS."; then
          PUBLIC_IP=""
          REMOTE_MODE="local"
        fi
      fi
      ;;
    custom)
      CUSTOM_REMOTE_HOST="$(input "Домен или IP" \
        "Enter a domain or IP, for example:

cloud.example.com
94.19.118.233" "")"
      [[ -n "$CUSTOM_REMOTE_HOST" ]] || die "Custom host cannot be empty."
      ;;
  esac
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
