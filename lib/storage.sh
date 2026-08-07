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
  local storages=()
  local opts=()
  local storage line type available percent

  # Keep this intentionally simple. pvesm itself already filters by
  # rootdir support, so the first field of every data row is a valid
  # container storage candidate.
  mapfile -t storages < <(
    pvesm status --content rootdir 2>/dev/null |
      awk 'NR > 1 && NF > 0 {print $1}'
  )

  # Fallback: parse storage.cfg if pvesm output parsing ever changes.
  if [[ ${#storages[@]} -eq 0 && -r /etc/pve/storage.cfg ]]; then
    mapfile -t storages < <(
      awk '
        /^[A-Za-z0-9_-]+:[[:space:]]+/ {
          split($1,a,":"); current=a[2]
        }
        /^[[:space:]]+content[[:space:]]+/ && $0 ~ /(^|,)rootdir(,|$)/ {
          if (current != "") print current
        }
      ' /etc/pve/storage.cfg
    )
  fi

  # Last-resort known storage verification: ask pvesm directly.
  if [[ ${#storages[@]} -eq 0 ]]; then
    while read -r storage; do
      [[ -n "$storage" ]] || continue
      if pvesm status --storage "$storage" --content rootdir 2>/dev/null |
           awk 'NR>1 && $3=="active" {found=1} END{exit !found}'; then
        storages+=("$storage")
      fi
    done < <(awk '/^[A-Za-z0-9_-]+:[[:space:]]+/ {split($1,a,":"); print a[2]}' /etc/pve/storage.cfg 2>/dev/null)
  fi

  # De-duplicate.
  if [[ ${#storages[@]} -gt 0 ]]; then
    mapfile -t storages < <(printf '%s\n' "${storages[@]}" | sed '/^$/d' | sort -u)
  fi

  for storage in "${storages[@]}"; do
    line="$(pvesm status --storage "$storage" 2>/dev/null | awk 'NR==2 {print; exit}')"
    [[ -n "$line" ]] || continue
    type="$(awk '{print $2}' <<<"$line")"
    available="$(awk '{print $6}' <<<"$line")"
    percent="$(awk '{print $7}' <<<"$line")"
    opts+=("$storage" "${type:-unknown} | available ${available:-unknown} KiB | ${percent:-N/A}")
  done

  if [[ ${#opts[@]} -eq 0 ]]; then
    echo >&2
    echo "===== PVE STORAGE STATUS =====" >&2
    pvesm status >&2 || true
    echo >&2
    echo "===== ROOTDIR STORAGE =====" >&2
    pvesm status --content rootdir >&2 || true
    echo >&2
    echo "===== STORAGE.CFG =====" >&2
    cat /etc/pve/storage.cfg >&2 || true
    die "No usable Proxmox storage for LXC rootdir was detected."
  fi

  # If there is exactly one candidate, select it automatically in Quick mode.
  if [[ ${#storages[@]} -eq 1 && "${INSTALL_MODE:-}" == "quick" ]]; then
    SYSTEM_STORAGE="${storages[0]}"
    ok "Using LXC system storage: $SYSTEM_STORAGE"
  else
    SYSTEM_STORAGE="$(menu "System storage" \
      "Where should the Nextcloud LXC system disk be stored?" \
      "${opts[@]}")"
  fi
}

select_data_disk() {
  detect_system_disks

  local opts=()
  local name size model type mounts disk label existing_part existing_mount
  while read -r name size type model; do
    [[ "$type" == "disk" ]] || continue
    disk="/dev/$name"

    if is_protected_disk "$disk"; then
      continue
    fi

    mounts="$(lsblk -nrpo MOUNTPOINT "$disk" | sed '/^$/d' | xargs || true)"
    label="$(lsblk -nrpo LABEL "$disk" | sed '/^$/d' | head -n1 || true)"

    if [[ "$label" == "NEXTCLOUD_DATA" || "$mounts" == *"/mnt/nextcloud-data"* ]]; then
      opts+=("$disk" "$size | ${model:-Unknown} | EXISTING Nextcloud data disk")
    elif [[ -n "$mounts" ]]; then
      opts+=("$disk" "$size | ${model:-Unknown} | mounted: $mounts")
    else
      opts+=("$disk" "$size | ${model:-Unknown} | available")
    fi
  done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL)

  opts+=("none" "Store data inside LXC system disk")

  DATA_DISK="$(menu "Nextcloud data" \
    "Choose a disk for user files. Proxmox system disks are hidden." \
    "${opts[@]}")"

  if [[ "$DATA_DISK" == "none" ]]; then
    DATA_MOUNT=""
    return
  fi

  DATA_MOUNT="/mnt/nextcloud-data"

  # Detect an already prepared disk from a previous installer run.
  existing_part="$(
    lsblk -lnpo NAME,LABEL "$DATA_DISK" |
      awk '$2=="NEXTCLOUD_DATA" {print $1; exit}'
  )"
  existing_mount="$(
    lsblk -lnpo MOUNTPOINT "$DATA_DISK" |
      awk '$1=="/mnt/nextcloud-data" {print $1; exit}'
  )"

  if [[ -n "$existing_part" || -n "$existing_mount" ]]; then
    if yesno "Existing Nextcloud disk" \
"An existing Nextcloud data filesystem was detected on:

$DATA_DISK
Partition: ${existing_part:-detected}
Mount: /mnt/nextcloud-data

Reuse it WITHOUT formatting?

Choose Yes to keep the existing filesystem and files.
Choose No to return to the main installation flow."; then
      reuse_data_disk "$DATA_DISK" "$existing_part"
      return
    else
      die "Existing data disk was not approved for reuse. No data was changed."
    fi
  fi

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

reuse_data_disk() {
  local disk="$1"
  local part="${2:-}"

  if [[ -z "$part" ]]; then
    part="$(findmnt -rn -S "$disk"* -o SOURCE 2>/dev/null | head -n1 || true)"
  fi

  if ! mountpoint -q "$DATA_MOUNT"; then
    [[ -n "$part" && -b "$part" ]] || die "Could not identify the existing Nextcloud data partition."
    mkdir -p "$DATA_MOUNT"
    mount "$part" "$DATA_MOUNT"
  fi

  mkdir -p "$DATA_MOUNT/data"
  chown -R 100033:100033 "$DATA_MOUNT"
  chmod 750 "$DATA_MOUNT" "$DATA_MOUNT/data"
  ok "Reusing existing data filesystem at $DATA_MOUNT. No formatting performed."
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
