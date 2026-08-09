#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.2.0"
LOG="/var/log/proxmox-storage-migrator.log"
BACKUP_DIR="/root/proxmox-storage-migrator-backups"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

CURRENT_STEP="Startup"

info(){ echo -e "\n${BLUE}==>${NC} $*"; echo "[$(date -Is)] $*" >> "$LOG"; }
ok(){ echo -e "${GREEN}OK:${NC} $*"; echo "[$(date -Is)] OK: $*" >> "$LOG"; }
warn(){ echo -e "${YELLOW}WARNING:${NC} $*"; echo "[$(date -Is)] WARNING: $*" >> "$LOG"; }
die(){ echo -e "${RED}ERROR:${NC} $*" >&2; echo "[$(date -Is)] ERROR: $*" >> "$LOG"; exit 1; }

on_error(){
  local rc=$?
  set +e
  echo
  echo "============================================================"
  echo " STORAGE MIGRATION FAILED"
  echo "============================================================"
  echo "Step: $CURRENT_STEP"
  echo "Exit: $rc"
  echo "Log:  $LOG"
  echo
  echo "Last 50 log lines:"
  tail -n 50 "$LOG" 2>/dev/null || true
  echo
  echo "The source disk was not intentionally erased by this wizard."
  exit "$rc"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox VE host."
command -v pct >/dev/null 2>&1 || die "pct not found. Run this on a Proxmox VE host."

mkdir -p "$BACKUP_DIR"
touch "$LOG"
chmod 600 "$LOG"

ensure_ui(){
  if ! command -v whiptail >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
  fi
}

menu(){
  whiptail --title "$1" --menu "$2" 22 86 14 "${@:3}" 3>&1 1>&2 2>&3
}
input(){
  whiptail --title "$1" --inputbox "$2" 12 82 "${3:-}" 3>&1 1>&2 2>&3
}
yesno(){
  whiptail --title "$1" --yesno "$2" 16 86
}
msg(){
  whiptail --title "$1" --msgbox "$2" 18 86
}

detect_system_disks(){
  SYSTEM_DISKS=()

  local src parent
  for src in $(findmnt -rn -o SOURCE / /boot /boot/efi 2>/dev/null | sort -u); do
    [[ "$src" == /dev/* ]] || continue
    parent="$(lsblk -ndo PKNAME "$src" 2>/dev/null || true)"
    if [[ -n "$parent" ]]; then
      SYSTEM_DISKS+=("/dev/$parent")
    elif [[ "$src" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+) ]]; then
      SYSTEM_DISKS+=("${BASH_REMATCH[0]}")
    fi
  done

  if command -v pvs >/dev/null 2>&1; then
    while read -r pv vg; do
      [[ "$vg" == "pve" ]] || continue
      parent="$(lsblk -ndo PKNAME "$pv" 2>/dev/null || true)"
      if [[ -n "$parent" ]]; then
        SYSTEM_DISKS+=("/dev/$parent")
      elif [[ "$pv" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+) ]]; then
        SYSTEM_DISKS+=("${BASH_REMATCH[0]}")
      fi
    done < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '{$1=$1};1')
  fi

  if [[ ${#SYSTEM_DISKS[@]} -gt 0 ]]; then
    mapfile -t SYSTEM_DISKS < <(printf '%s\n' "${SYSTEM_DISKS[@]}" | sort -u)
  fi
}

is_system_disk(){
  local d="$1" x
  for x in "${SYSTEM_DISKS[@]:-}"; do
    [[ "$d" == "$x" ]] && return 0
  done
  return 1
}

disk_stable_id(){
  local disk="$1"
  local real
  real="$(readlink -f "$disk")"

  local id link
  for link in /dev/disk/by-id/*; do
    [[ -e "$link" ]] || continue
    id="$(readlink -f "$link")"
    if [[ "$id" == "$real" && "$link" != *-part* ]]; then
      echo "$link"
      return 0
    fi
  done
  echo "$disk"
}

list_disks_text(){
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
}

select_ct(){
  local opts=()
  while read -r id status name; do
    [[ "$id" == "VMID" ]] && continue
    opts+=("$id" "$status | $name")
  done < <(pct list)

  [[ ${#opts[@]} -gt 0 ]] || die "No LXC containers found."
  CTID="$(menu "LXC container" "Select the Nextcloud container:" "${opts[@]}")"
}

detect_bind_mounts(){
  BIND_OPTS=()
  while IFS= read -r line; do
    local key value host mp
    key="${line%%:*}"
    value="${line#*: }"
    [[ "$key" =~ ^mp[0-9]+$ ]] || continue
    host="${value%%,*}"
    mp="$(sed -n 's/.*mp=\([^,]*\).*/\1/p' <<<"$value")"
    BIND_OPTS+=("$key" "$host -> ${mp:-unknown}")
  done < <(pct config "$CTID")

  [[ ${#BIND_OPTS[@]} -gt 0 ]] || die "No bind mounts (mp0/mp1/...) found in CT $CTID."
}

select_source_mount(){
  detect_bind_mounts
  SOURCE_MP_KEY="$(menu "Source storage" "Select the existing Nextcloud data bind mount:" "${BIND_OPTS[@]}")"
  local line value
  line="$(pct config "$CTID" | grep "^${SOURCE_MP_KEY}:")"
  value="${line#*: }"
  SOURCE_HOST="${value%%,*}"
  SOURCE_CONTAINER="$(sed -n 's/.*mp=\([^,]*\).*/\1/p' <<<"$value")"
  [[ -d "$SOURCE_HOST" ]] || die "Source host path does not exist: $SOURCE_HOST"
}

select_free_disk(){
  local title="$1"
  local exclude1="${2:-}"
  local exclude2="${3:-}"
  local opts=()
  local name size type model serial d mounts

  detect_system_disks

  while read -r name size type model serial; do
    [[ "$type" == "disk" ]] || continue
    d="/dev/$name"
    is_system_disk "$d" && continue
    [[ "$d" == "$exclude1" || "$d" == "$exclude2" ]] && continue

    mounts="$(lsblk -nrpo MOUNTPOINT "$d" | sed '/^$/d' | xargs || true)"
    opts+=("$d" "$size | ${model:-Unknown} | ${serial:-no-serial} | ${mounts:-not mounted}")
  done < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL,SERIAL)

  [[ ${#opts[@]} -gt 0 ]] || die "No eligible non-system disks found."
  SELECTED_DISK="$(menu "$title" "Select a physical disk:" "${opts[@]}")"
}

disk_summary(){
  local d="$1"
  lsblk -dn -o PATH,SIZE,MODEL,SERIAL "$d" | xargs
}

confirm_erase_disk(){
  local d="$1"
  local summary
  summary="$(disk_summary "$d")"
  msg "DANGER" "The following disk will be ERASED:

$summary

Device: $d

All existing partitions/filesystems on this disk will be destroyed."

  local typed
  typed="$(input "Confirm destructive operation" "Type the exact device name:

$d" "")"
  [[ "$typed" == "$d" ]] || die "Disk confirmation did not match."
}

confirm_two_disks(){
  local d1="$1" d2="$2"
  local s1 s2 typed
  s1="$(disk_summary "$d1")"
  s2="$(disk_summary "$d2")"

  msg "RAID1 DANGER" "These TWO disks will be ERASED:

1) $s1
2) $s2

The existing source disk is NOT in this list and will be kept."

  typed="$(input "Confirm RAID1 creation" "Type exactly:

CREATE RAID1" "")"
  [[ "$typed" == "CREATE RAID1" ]] || die "RAID1 confirmation failed."
}

install_tools(){
  CURRENT_STEP="Installing required tools"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y rsync gdisk parted e2fsprogs smartmontools
}

nextcloud_maintenance_on(){
  pct exec "$CTID" -- bash -lc \
    'if [[ -f /var/www/nextcloud/occ ]]; then cd /var/www/nextcloud; runuser -u www-data -- php occ maintenance:mode --on || true; fi'
  pct exec "$CTID" -- systemctl stop nginx 2>/dev/null || true
  pct exec "$CTID" -- systemctl stop cron 2>/dev/null || true
}

nextcloud_maintenance_off(){
  pct exec "$CTID" -- systemctl start nginx 2>/dev/null || true
  pct exec "$CTID" -- systemctl start cron 2>/dev/null || true
  pct exec "$CTID" -- bash -lc \
    'if [[ -f /var/www/nextcloud/occ ]]; then cd /var/www/nextcloud; runuser -u www-data -- php occ maintenance:mode --off || true; fi'
}

rsync_data(){
  local src="$1" dst="$2"
  CURRENT_STEP="Copying data"
  info "First rsync: $src -> $dst"
  rsync -aHAX --numeric-ids --info=progress2 "$src"/ "$dst"/

  info "Verification rsync (second pass)"
  rsync -aHAX --numeric-ids --delete --info=stats2 "$src"/ "$dst"/
}

backup_ct_config(){
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp "/etc/pve/lxc/${CTID}.conf" "$BACKUP_DIR/${CTID}.conf.$stamp"
  ok "Container config backed up to $BACKUP_DIR"
}

switch_bind_mount(){
  local new_host="$1"
  backup_ct_config
  pct set "$CTID" -delete "$SOURCE_MP_KEY"
  pct set "$CTID" "-$SOURCE_MP_KEY" "$new_host,mp=$SOURCE_CONTAINER"
}

prepare_single_ext4(){
  local disk="$1" mountpoint="$2" label="$3"
  CURRENT_STEP="Preparing new ext4 disk"

  confirm_erase_disk "$disk"

  while read -r part mnt; do
    [[ -n "${mnt:-}" ]] && umount "$part" || true
  done < <(lsblk -lnpo NAME,MOUNTPOINT "$disk" | tail -n +2)

  wipefs -af "$disk"
  sgdisk --zap-all "$disk"
  sgdisk -n 1:0:0 -t 1:8300 -c 1:"$label" "$disk"
  partprobe "$disk"
  udevadm settle

  local part
  if [[ "$disk" =~ nvme|mmcblk ]]; then part="${disk}p1"; else part="${disk}1"; fi

  mkfs.ext4 -F -L "$label" "$part"
  mkdir -p "$mountpoint"

  local uuid
  uuid="$(blkid -s UUID -o value "$part")"
  echo "UUID=$uuid $mountpoint ext4 defaults,noatime 0 2" >> /etc/fstab
  mount "$mountpoint"

  chown -R 100033:100033 "$mountpoint"
  chmod 750 "$mountpoint"
}

replace_single_disk(){
  select_ct
  select_source_mount
  select_free_disk "New replacement disk"

  local new_disk="$SELECTED_DISK"
  local target="/mnt/nextcloud-new"

  install_tools

  if ! yesno "Replace data disk" \
"Source:
$SOURCE_HOST -> $SOURCE_CONTAINER

New disk:
$(disk_summary "$new_disk")

Plan:
1. Format NEW disk only
2. Copy all data
3. Stop Nextcloud briefly
4. Final sync
5. Switch the existing bind mount
6. Start Nextcloud
7. KEEP the old disk untouched

Continue?"; then
    exit 0
  fi

  prepare_single_ext4 "$new_disk" "$target" "NEXTCLOUD_NEW"

  # Warm copy while server is online.
  rsync -aHAX --numeric-ids --info=progress2 "$SOURCE_HOST"/ "$target"/

  nextcloud_maintenance_on
  rsync_data "$SOURCE_HOST" "$target"
  switch_bind_mount "$target"
  nextcloud_maintenance_off

  ok "Migration completed. OLD source remains at: $SOURCE_HOST"
  msg "Completed" "Nextcloud storage has been switched to:

$target

Old source was NOT erased:
$SOURCE_HOST

Check Nextcloud carefully before removing the old disk."
}

create_zfs_mirror_target(){
  local d1="$1" d2="$2" pool="$3"
  CURRENT_STEP="Creating ZFS mirror"

  DEBIAN_FRONTEND=noninteractive apt-get install -y zfsutils-linux

  local id1 id2
  id1="$(disk_stable_id "$d1")"
  id2="$(disk_stable_id "$d2")"

  confirm_two_disks "$d1" "$d2"

  wipefs -af "$d1"
  wipefs -af "$d2"
  zpool create -f -o ashift=12 "$pool" mirror "$id1" "$id2"
  zfs create "$pool/nextcloud"
  zfs set mountpoint="/mnt/$pool" "$pool/nextcloud"

  mkdir -p "/mnt/$pool"
  chown -R 100033:100033 "/mnt/$pool"
  chmod 750 "/mnt/$pool"
}

create_mdadm_mirror_target(){
  local d1="$1" d2="$2" mountpoint="$3"
  CURRENT_STEP="Creating mdadm RAID1"

  DEBIAN_FRONTEND=noninteractive apt-get install -y mdadm

  local id1 id2
  id1="$(disk_stable_id "$d1")"
  id2="$(disk_stable_id "$d2")"

  confirm_two_disks "$d1" "$d2"

  wipefs -af "$d1"
  wipefs -af "$d2"
  mdadm --create /dev/md0 --level=1 --raid-devices=2 "$id1" "$id2"

  # It is valid to format while RAID1 syncs.
  mkfs.ext4 -F -L NEXTCLOUD_RAID1 /dev/md0
  mkdir -p "$mountpoint"
  local uuid
  uuid="$(blkid -s UUID -o value /dev/md0)"
  echo "UUID=$uuid $mountpoint ext4 defaults,noatime 0 2" >> /etc/fstab
  mount "$mountpoint"
  chown -R 100033:100033 "$mountpoint"
  chmod 750 "$mountpoint"
}

migrate_to_raid1(){
  select_ct
  select_source_mount
  select_free_disk "RAID1 disk 1"
  local d1="$SELECTED_DISK"
  select_free_disk "RAID1 disk 2" "$d1"
  local d2="$SELECTED_DISK"

  local method
  method="$(menu "RAID1 type" "Choose RAID1 implementation:" \
    zfs "ZFS Mirror (recommended for Proxmox)" \
    mdadm "Linux mdadm RAID1 + ext4")"

  install_tools

  if ! yesno "Migration plan" \
"Existing data:
$SOURCE_HOST -> $SOURCE_CONTAINER

NEW RAID1 disks:
$(disk_summary "$d1")
$(disk_summary "$d2")

The two NEW disks will be ERASED.
The OLD source disk will be kept after migration.

Continue?"; then
    exit 0
  fi

  local target
  if [[ "$method" == "zfs" ]]; then
    local pool="nextcloud-raid"
    if zpool list "$pool" >/dev/null 2>&1; then
      pool="$(input "ZFS pool" "Pool 'nextcloud-raid' already exists. Enter another pool name:" "nextcloud-raid2")"
    fi
    create_zfs_mirror_target "$d1" "$d2" "$pool"
    target="/mnt/$pool"
  else
    [[ ! -e /dev/md0 ]] || die "/dev/md0 already exists. This wizard will not overwrite it."
    target="/mnt/nextcloud-raid1"
    create_mdadm_mirror_target "$d1" "$d2" "$target"
  fi

  CURRENT_STEP="Initial data copy"
  info "Initial online copy to RAID1"
  rsync -aHAX --numeric-ids --info=progress2 "$SOURCE_HOST"/ "$target"/

  CURRENT_STEP="Final migration"
  nextcloud_maintenance_on
  rsync_data "$SOURCE_HOST" "$target"
  switch_bind_mount "$target"
  nextcloud_maintenance_off

  ok "Nextcloud has been switched to RAID1 at $target"
  msg "RAID1 migration complete" "New storage:
$target

Old source is still preserved:
$SOURCE_HOST

Do NOT erase the old disk until:
• Nextcloud opens
• files are visible
• upload/download works
• RAID status is healthy

ZFS:
zpool status

mdadm:
cat /proc/mdstat
mdadm --detail /dev/md0"
}

add_independent_disk(){
  select_ct
  select_free_disk "New independent disk"
  local d="$SELECTED_DISK"

  local mpnum
  mpnum="$(input "Bind mount number" "Enter mount slot number (for example 1 for mp1):" "1")"
  local host="/mnt/nextcloud-data${mpnum}"
  local container="/mnt/data${mpnum}"

  install_tools
  prepare_single_ext4 "$d" "$host" "NEXTCLOUD_DATA${mpnum}"

  pct set "$CTID" "-mp${mpnum}" "$host,mp=$container"

  ok "Disk attached to CT $CTID: $host -> $container"
  msg "Completed" "New disk attached:

Host:
$host

Container:
$container

For Nextcloud External Storage use:
$container"
}

diagnostics(){
  clear
  echo "=== Proxmox Storage Migrator diagnostics ==="
  echo
  echo "--- Containers ---"
  pct list
  echo
  echo "--- Disks ---"
  list_disks_text
  echo
  echo "--- Mounts ---"
  df -hT
  echo
  echo "--- Proxmox storage ---"
  pvesm status || true
  echo
  echo "--- ZFS ---"
  zpool status 2>/dev/null || true
  echo
  echo "--- mdadm ---"
  cat /proc/mdstat || true
  echo
  read -r -p "Press Enter..."
}


human_bytes_from_kib() {
  local kib="${1:-0}"
  awk -v k="$kib" 'BEGIN{
    b=k*1024;
    if (b>=1099511627776) printf "%.1f TB", b/1099511627776;
    else if (b>=1073741824) printf "%.1f GB", b/1073741824;
    else if (b>=1048576) printf "%.1f MB", b/1048576;
    else printf "%.0f KB", k;
  }'
}

storage_overview() {
  clear || true
  echo "============================================================"
  echo " Proxmox Storage Overview"
  echo "============================================================"
  echo
  echo "### Physical disks"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
  echo
  echo "### Proxmox storages"
  pvesm status || true
  echo
  echo "### Filesystems"
  df -hT
  echo
  echo "### LXC containers"
  pct list || true
  echo
  echo "### RAID"
  zpool status 2>/dev/null || true
  cat /proc/mdstat 2>/dev/null || true
  echo
  echo "### LVM"
  pvs 2>/dev/null || true
  vgs 2>/dev/null || true
  lvs 2>/dev/null || true
  echo
  read -r -p "Press Enter..."
}

expand_lxc_rootfs() {
  select_ct
  local current add
  current="$(pct config "$CTID" | awk -F'[:=, ]+' '/^rootfs:/ {for(i=1;i<=NF;i++) if($i=="size") print $(i+1)}')"
  add="$(input "Expand LXC system disk" \
"Current rootfs size: ${current:-unknown}

Enter how much to ADD, for example:
10G
20G
50G" "10G")"

  [[ "$add" =~ ^[0-9]+[GMTP]$ ]] || die "Use format like 10G or 100G."

  if ! yesno "Confirm rootfs resize" \
"Container: $CTID
Current rootfs: ${current:-unknown}
Increase by: $add

This operation normally cannot be shrunk automatically later.

Continue?"; then
    return 0
  fi

  CURRENT_STEP="Expanding LXC rootfs"
  pct resize "$CTID" rootfs "+$add"
  ok "LXC rootfs expanded."
  pct exec "$CTID" -- df -hT / || true
  read -r -p "Press Enter..."
}

add_proxmox_directory_disk() {
  select_free_disk "New Proxmox storage disk"
  local d="$SELECTED_DISK"
  local storage_name
  storage_name="$(input "Storage name" "Proxmox Storage ID:" "data-storage")"
  [[ "$storage_name" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid storage ID."

  local host="/mnt/$storage_name"
  install_tools

  if ! yesno "Add Proxmox storage" \
"Disk:
$(disk_summary "$d")

The disk will be ERASED and formatted as ext4.

It will be added to Proxmox as Directory Storage:
$storage_name
$host

Continue?"; then
    return 0
  fi

  prepare_single_ext4 "$d" "$host" "PVE_${storage_name}"

  pvesm add dir "$storage_name" \
    --path "$host" \
    --content images,rootdir,backup,iso,vztmpl

  ok "New Proxmox Directory Storage added: $storage_name"
  pvesm status
  read -r -p "Press Enter..."
}

storage_advisor() {
  clear || true
  detect_system_disks

  echo "============================================================"
  echo " Storage Upgrade Advisor"
  echo "============================================================"
  echo

  local disk_count=0 unused_count=0 system_count=0
  local name type d mounts
  while read -r name type; do
    [[ "$type" == "disk" ]] || continue
    disk_count=$((disk_count+1))
    d="/dev/$name"
    if is_system_disk "$d"; then
      system_count=$((system_count+1))
    else
      mounts="$(lsblk -nrpo MOUNTPOINT "$d" | sed '/^$/d' | xargs || true)"
      [[ -z "$mounts" ]] && unused_count=$((unused_count+1))
    fi
  done < <(lsblk -dn -o NAME,TYPE)

  echo "Detected physical disks: $disk_count"
  echo "Detected Proxmox system disks: $system_count"
  echo "Unused non-system disks: $unused_count"
  echo

  echo "Current disk layout:"
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL
  echo

  echo "Recommended development paths:"
  echo

  if [[ "$unused_count" -ge 2 ]]; then
    echo "[A] You have at least two unused disks."
    echo "    Good path: create RAID1/ZFS Mirror and migrate Nextcloud data."
    echo "    Benefit: one-disk fault tolerance."
    echo
  elif [[ "$unused_count" -eq 1 ]]; then
    echo "[A] You have one unused disk."
    echo "    Options:"
    echo "    - add it as independent Nextcloud External Storage;"
    echo "    - replace the current data disk if the new disk is larger;"
    echo "    - keep it free until a second matching disk is available for RAID1."
    echo
  else
    echo "[A] No clearly unused non-system disks were detected."
    echo "    Add a new disk before migration or RAID creation."
    echo
  fi

  local root_pct
  root_pct="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
  if [[ -n "$root_pct" && "$root_pct" -ge 80 ]]; then
    echo "[B] Proxmox root filesystem usage is ${root_pct}%."
    echo "    Consider cleaning logs/ISO files or expanding system storage."
    echo
  fi

  local lvm_avail
  lvm_avail="$(pvesm status --storage local-lvm 2>/dev/null | awk 'NR==2 {print $6}')"
  if [[ "$lvm_avail" =~ ^[0-9]+$ ]]; then
    echo "[C] local-lvm available: $(human_bytes_from_kib "$lvm_avail")."
    echo "    You can expand an LXC rootfs if the container system disk becomes tight."
    echo
  fi

  if mountpoint -q /mnt/nextcloud-data; then
    echo "[D] Existing Nextcloud host data mount detected: /mnt/nextcloud-data"
    echo "    Safe upgrade options:"
    echo "    - replace with one larger disk, preserving the old disk;"
    echo "    - migrate to two new disks in RAID1;"
    echo "    - add a second independent disk as External Storage."
    echo
  fi

  if zpool status >/dev/null 2>&1; then
    echo "[E] ZFS is already present."
    echo "    Consider regular scrub, SMART monitoring and snapshots."
    echo
  else
    echo "[E] ZFS pool not detected."
    echo "    For two new matching data disks, ZFS Mirror is a strong upgrade path."
    echo
  fi

  echo "[F] Regardless of RAID, keep a separate backup."
  echo "    RAID protects against a disk failure, not deletion, ransomware or corruption."
  echo
  read -r -p "Press Enter..."
}

disk_management_menu() {
  while true; do
    local action
    action="$(menu "Disk management" \
"Choose a disk/storage operation.

Destructive actions always require separate confirmation." \
      overview "Show disks, mounts, Proxmox storage and RAID" \
      advisor "Show upgrade / modernization recommendations" \
      addnc "Add independent disk to Nextcloud LXC" \
      replace "Replace current Nextcloud data disk with larger disk (no RAID)" \
      raid1 "Migrate current Nextcloud data to 2 new disks RAID1" \
      addpve "Add a new disk as Proxmox Directory Storage" \
      rootfs "Expand an LXC system disk (rootfs)" \
      diag "Detailed diagnostics" \
      back "Back")" || return 0

    case "$action" in
      overview) storage_overview ;;
      advisor) storage_advisor ;;
      addnc) add_independent_disk; return 0 ;;
      replace) replace_single_disk; return 0 ;;
      raid1) migrate_to_raid1; return 0 ;;
      addpve) add_proxmox_directory_disk ;;
      rootfs) expand_lxc_rootfs ;;
      diag) diagnostics ;;
      *) return 0 ;;
    esac
  done
}

main(){
  ensure_ui
  detect_system_disks

  while true; do
    local action
    action="$(menu "Proxmox Storage Manager v$VERSION" \
"Disk management and migration wizard for an existing Proxmox/Nextcloud system." \
      disks "Disk management / migration / upgrades" \
      advisor "Upgrade advisor" \
      diag "Diagnostics" \
      exit "Exit")" || exit 0

    case "$action" in
      disks) disk_management_menu ;;
      advisor) storage_advisor ;;
      diag) diagnostics ;;
      *) exit 0 ;;
    esac
  done
}

main "$@"
