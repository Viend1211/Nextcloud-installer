#!/usr/bin/env bash
set -Eeuo pipefail

admin_select_ct() {
  local opts=()
  while read -r id status name; do
    [[ "$id" == "VMID" ]] && continue
    opts+=("$id" "$status | $name")
  done < <(pct list)
  [[ ${#opts[@]} -gt 0 ]] || { msg "LXC" "No containers found."; return 1; }
  ADMIN_CTID="$(menu "LXC container" "Select container:" "${opts[@]}")"
}

admin_nextcloud_occ() {
  admin_select_ct || return 0
  local action
  action="$(menu "Nextcloud" "Choose action:" \
    status "Show status" \
    users "List users" \
    reset "Reset user password" \
    trusted "Show trusted_domains" \
    addtrusted "Add trusted domain/IP" \
    scan "Scan all files" \
    repair "Run maintenance:repair" \
    back "Back")" || return 0

  case "$action" in
    status) pct exec "$ADMIN_CTID" -- bash -lc 'cd /var/www/nextcloud && runuser -u www-data -- php occ status' ;;
    users) pct exec "$ADMIN_CTID" -- bash -lc 'cd /var/www/nextcloud && runuser -u www-data -- php occ user:list' ;;
    reset)
      local u
      u="$(input "Reset password" "Nextcloud username:" "admin")"
      pct exec "$ADMIN_CTID" -- bash -lc "cd /var/www/nextcloud && runuser -u www-data -- php occ user:resetpassword '$u'"
      ;;
    trusted) pct exec "$ADMIN_CTID" -- bash -lc 'cd /var/www/nextcloud && runuser -u www-data -- php occ config:system:get trusted_domains' ;;
    addtrusted)
      local h i
      h="$(input "Trusted host" "Domain or IP:" "")"
      i="$(input "Index" "trusted_domains index:" "2")"
      pct exec "$ADMIN_CTID" -- bash -lc "cd /var/www/nextcloud && runuser -u www-data -- php occ config:system:set trusted_domains '$i' --value='$h'"
      ;;
    scan) pct exec "$ADMIN_CTID" -- bash -lc 'cd /var/www/nextcloud && runuser -u www-data -- php occ files:scan --all' ;;
    repair) pct exec "$ADMIN_CTID" -- bash -lc 'cd /var/www/nextcloud && runuser -u www-data -- php occ maintenance:repair' ;;
    *) return 0 ;;
  esac
  echo
  read -r -p "Press Enter..."
}

admin_container_tools() {
  admin_select_ct || return 0
  local action
  action="$(menu "LXC tools" "Choose action:" \
    enter "Open shell" \
    rootpass "Reset root password" \
    config "Show pct config" \
    ip "Show IP" \
    disk "Show disk usage" \
    back "Back")" || return 0

  case "$action" in
    enter) pct enter "$ADMIN_CTID" ;;
    rootpass) pct exec "$ADMIN_CTID" -- passwd root ;;
    config) pct config "$ADMIN_CTID" ;;
    ip) pct exec "$ADMIN_CTID" -- hostname -I ;;
    disk) pct exec "$ADMIN_CTID" -- df -hT ;;
    *) return 0 ;;
  esac
  echo
  read -r -p "Press Enter..."
}

admin_diagnostics() {
  clear || true
  echo "=== Proxmox / Nextcloud diagnostics ==="
  pveversion || true
  echo; pct list || true
  echo; pvesm status || true
  echo; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL || true
  echo; df -hT || true
  echo; zpool status 2>/dev/null || true
  echo; cat /proc/mdstat 2>/dev/null || true
  echo
  read -r -p "Press Enter..."
}
