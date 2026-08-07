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

  # Find an active storage that supports container templates (vztmpl).
  TEMPLATE_STORAGE="$(
    pvesm status --content vztmpl 2>/dev/null |
      awk 'NR>1 && $3=="active" {print $1; exit}'
  )"

  [[ -n "$TEMPLATE_STORAGE" ]] || die "No active Proxmox storage supporting vztmpl templates was found."

  TEMPLATE_PATH="$TEMPLATE_STORAGE:vztmpl/$template"

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$TEMPLATE_PATH"; then
    pveam download "$TEMPLATE_STORAGE" "$template"
  fi
}

create_lxc() {
  download_debian_template
  create_lxc_only
  start_lxc_and_wait
}
