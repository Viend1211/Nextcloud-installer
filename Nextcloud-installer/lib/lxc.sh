#!/usr/bin/env bash

choose_network() {
  local nmode
  nmode="$(menu "Network" "Choose network configuration:" \
    dhcp "DHCP (recommended for quick setup)" \
    static "Static IPv4")"

  BRIDGE="$(input "Bridge" "Proxmox bridge:" "vmbr0")"

  if [[ "$nmode" == "dhcp" ]]; then
    NETCONF="name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth"
  else
    local ip gw
    ip="$(input "Static IP" "IPv4 with CIDR, for example 192.168.1.50/24:" "")"
    validate_ipv4_cidr "$ip" || die "Invalid IPv4/CIDR."
    gw="$(input "Gateway" "IPv4 gateway, for example 192.168.1.1:" "")"
    [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid gateway."
    NETCONF="name=eth0,bridge=$BRIDGE,ip=$ip,gw=$gw,type=veth"
  fi
}

download_debian_template() {
  pveam update

  local template
  template="$(pveam available --section system \
    | awk '{print $2}' \
    | grep -E '^debian-(13|12)-standard_.*_amd64\.tar\.(zst|gz|xz)$' \
    | sort -V | tail -n1)"

  [[ -n "$template" ]] || die "Debian 12/13 LXC template not found."

  TEMPLATE_STORAGE="local"
  TEMPLATE_PATH="$TEMPLATE_STORAGE:vztmpl/$template"

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$TEMPLATE_PATH"; then
    pveam download "$TEMPLATE_STORAGE" "$template"
  fi
}

create_lxc() {
  download_debian_template

  info "Creating LXC $CTID on $SYSTEM_STORAGE"

  LXC_ROOT_PASS="$(randpass)"

  pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$HOSTNAME" \
    --rootfs "$SYSTEM_STORAGE:$ROOTFS_GB" \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap "$SWAP_MB" \
    --net0 "$NETCONF" \
    --unprivileged 1 \
    --onboot 1 \
    --start 0 \
    --password "$LXC_ROOT_PASS" \
    --features keyctl=1,nesting=1

  if [[ -n "${DATA_MOUNT:-}" ]]; then
    pct set "$CTID" -mp0 "$DATA_MOUNT,mp=/mnt/data"
  fi

  pct start "$CTID"

  info "Waiting for container network"
  CONTAINER_IP=""
  for _ in $(seq 1 75); do
    sleep 2
    CONTAINER_IP="$(pct exec "$CTID" -- bash -lc "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
    [[ -n "$CONTAINER_IP" ]] && break
  done
  [[ -n "$CONTAINER_IP" ]] || die "LXC started but did not get an IP address."
}
