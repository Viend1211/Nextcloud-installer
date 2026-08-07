#!/usr/bin/env bash

backup_apt_sources() {
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "/root/nextcloud-installer-backups/$stamp"
  cp -a /etc/apt/sources.list* "/root/nextcloud-installer-backups/$stamp/" 2>/dev/null || true
  echo "$stamp"
}

fix_proxmox_repositories_if_needed() {
  info "Checking Proxmox package repositories"

  local bad=0
  if grep -Rqs "enterprise.proxmox.com" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    if ! apt-get update >/tmp/nc-apt-update.log 2>&1; then
      if grep -q "401.*Unauthorized" /tmp/nc-apt-update.log; then
        bad=1
      fi
    fi
  else
    apt-get update >/tmp/nc-apt-update.log 2>&1 || true
  fi

  if [[ "$bad" -eq 0 ]]; then
    ok "APT repositories are usable."
    return
  fi

  warn "Enterprise repositories are enabled but no valid subscription appears to be available."

  if ! yesno "Proxmox repositories" \
"Proxmox Enterprise repositories returned 401 Unauthorized.

The installer can:
• back up current APT repository files
• disable Enterprise PVE/Ceph entries
• enable the official pve-no-subscription repository for Debian 13 / Proxmox VE 9

Continue?"; then
    die "Repository setup was cancelled."
  fi

  local stamp
  stamp="$(backup_apt_sources)"
  info "APT repository backup: /root/nextcloud-installer-backups/$stamp"

  # Disable enterprise source files if present.
  for f in /etc/apt/sources.list.d/pve-enterprise.sources \
           /etc/apt/sources.list.d/ceph.sources \
           /etc/apt/sources.list.d/pve-enterprise.list \
           /etc/apt/sources.list.d/ceph.list; do
    [[ -f "$f" ]] && mv "$f" "${f}.disabled"
  done

  # Also comment any legacy enterprise lines elsewhere.
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    sed -i '/enterprise\.proxmox\.com/s/^[[:space:]]*deb/# deb/' "$f" || true
  done < <(grep -RIl "enterprise.proxmox.com" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true)

  cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

  apt-get update
  ok "Proxmox no-subscription repository enabled."
}
