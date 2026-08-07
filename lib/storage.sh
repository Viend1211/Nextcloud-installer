#!/usr/bin/env bash

declare -a SYSTEM_DISKS=()

detect_system_disks() {
  SYSTEM_DISKS=()

  local sources dev parent
  # Root filesystem and Proxmox logical volumes may sit on LVM/mapper.
  mapfile -t sources < <(findmnt -rn -o SOURCE / /boot /boot/efi 2>/dev/null | sort -u)

  for dev in "${sources[@]}"; do
    [[ "$dev" == /dev/* ]] || continue
    parent="$(lsblk -ndo PKNAME "$dev" 2>/dev/null || true)"
    if [[ -n "$parent" ]]; then
      SYSTEM_DISKS+=("/dev/$parent")
    elif [[ "$dev" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+) ]]; then
      SYSTEM_DISKS+=("${BASH_REMATCH[0]}")
    fi
  done

  # Detect PVs backing pve VG.
  if command -v pvs >/dev/null 2>&1; then
    while read -r pv vg; do
      [[ "$vg" == "pve" ]] || continue
      parent="$(lsblk -ndo PKNAME "$pv" 2>/dev/null || true)"
      if [[ -n "$parent" ]]; then
        SYSTEM_DISKS+=("/dev/$parent")
      else
        [[ "$pv" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+) ]] && SYSTEM_DISKS+=("${BASH_REMATCH[0]}")
      fi
    done < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '{$1=$1};1')
  fi

  mapfile -t SYSTEM_DISKS < <(printf '%s\n' "${SYSTEM_DISKS[@]}" | sort -u)
}

is_protected_disk() {
  local d="$1" p
  for p in "${SYSTEM_DISKS[@]}"; do
    [[ "$d" == "$p" ]] && return 0
  done
  return 1
}

select_pve_storage() {
  local opts=()
  while read -r storage type avail active content; do
    [[ "$active" == "1" ]] || continue
    [[ "$content" == *rootdir* ]] || continue
    opts+=("$storage" "$type, available ${avail:-unknown}")
  done < <(pvesm status --content rootdir | awk 'NR>1 {print $1,$2,$6,$3,$7}')

  if [[ ${#opts[@]} -eq 0 ]]; then
    die "No active Proxmox storage with rootdir support was found."
  fi

  SYSTEM_STORAGE="$(menu "System storage" "Where should the Nextcloud LXC system disk be stored?" "${opts[@]}")"
}

select_data_disk() {
  detect_system_disks

  local opts=()
  local name size model type mounts disk
  while read -r name size type model; do
    [[ "$type" == "disk" ]] || continue
    disk="/dev/$name"

    if is_protected_disk "$disk"; then
      continue
    fi

    mounts="$(lsblk -nrpo MOUNTPOINT "$disk" | sed '/^$/d' | xargs || true)"
    if [[ -n "$mounts" ]]; then
      opts+=("$disk" "$size | ${model:-Unknown} | mounted: $mounts")
    else
      opts+=("$disk" "$size | ${model:-Unknown} | available")
    fi
  done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL)

  opts+=("none" "Store data inside LXC system disk")

  DATA_DISK="$(menu "Nextcloud data" "Choose a disk for user files. Proxmox system disks are hidden." "${opts[@]}")"

  if [[ "$DATA_DISK" == "none" ]]; then
    DATA_MOUNT=""
    return
  fi

  DATA_MOUNT="/mnt/nextcloud-data"

  local size model serial
  size="$(lsblk -dn -o SIZE "$DATA_DISK" | xargs)"
  model="$(lsblk -dn -o MODEL "$DATA_DISK" | xargs)"
  serial="$(lsblk -dn -o SERIAL "$DATA_DISK" | xargs)"

  msg "DANGER" "Selected data disk:

Device: $DATA_DISK
Size: $size
Model: ${model:-Unknown}
Serial: ${serial:-Unknown}

ALL DATA ON THIS DISK WILL BE DESTROYED."

  local confirm
  confirm="$(input "Confirm disk wipe" "Type the exact device name to confirm:

$DATA_DISK" "")"
  [[ "$confirm" == "$DATA_DISK" ]] || die "Disk confirmation did not match."

  prepare_data_disk
}

prepare_data_disk() {
  is_protected_disk "$DATA_DISK" && die "Safety check: selected disk is a Proxmox system disk."

  info "Preparing $DATA_DISK for Nextcloud data"
  apt-get install -y gdisk parted e2fsprogs

  while read -r part mnt; do
    [[ -n "${mnt:-}" ]] && umount "$part" || true
  done < <(lsblk -lnpo NAME,MOUNTPOINT "$DATA_DISK" | tail -n +2)

  wipefs -af "$DATA_DISK"
  sgdisk --zap-all "$DATA_DISK"
  sgdisk -n 1:0:0 -t 1:8300 -c 1:NEXTCLOUD_DATA "$DATA_DISK"
  partprobe "$DATA_DISK"
  udevadm settle

  local part
  if [[ "$DATA_DISK" =~ nvme|mmcblk ]]; then part="${DATA_DISK}p1"; else part="${DATA_DISK}1"; fi
  [[ -b "$part" ]] || die "Partition $part was not created."

  mkfs.ext4 -F -L NEXTCLOUD_DATA "$part"
  mkdir -p "$DATA_MOUNT"

  local uuid
  uuid="$(blkid -s UUID -o value "$part")"
  cp -a /etc/fstab "/etc/fstab.nextcloud-installer.$(date +%Y%m%d-%H%M%S).bak"
  sed -i "\|[[:space:]]$DATA_MOUNT[[:space:]]|d" /etc/fstab
  echo "UUID=$uuid $DATA_MOUNT ext4 defaults,noatime 0 2" >> /etc/fstab
  mount "$DATA_MOUNT"

  # Unprivileged LXC www-data (33) -> host uid/gid 100033.
  mkdir -p "$DATA_MOUNT/data"
  chown -R 100033:100033 "$DATA_MOUNT"
  chmod 750 "$DATA_MOUNT" "$DATA_MOUNT/data"
}
