#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.2.3"
LOG_FILE="/var/log/forgejo-installer.log"
WORKDIR="/tmp/forgejo-installer"
DEFAULT_HOSTNAME="forgejo"
DEFAULT_DISK_GB=24
DEFAULT_DATA_GB=100
DEFAULT_CORES=2
DEFAULT_RAM=2048
DEFAULT_SWAP=512
DEFAULT_BRIDGE="vmbr0"
DEFAULT_FORGEJO_LTS="15.0.5"
DEFAULT_FORGEJO_STABLE="16.0.1"

mkdir -p "$WORKDIR"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_CYAN='\033[36m'

banner() {
  clear || true
  printf '%b\n' "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  printf '%b\n' "${C_CYAN}${C_BOLD}║                    F O R G E J O                         ║${C_RESET}"
  printf '%b\n' "${C_CYAN}${C_BOLD}║               Proxmox Installer v${VERSION}                  ║${C_RESET}"
  printf '%b\n' "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RESET}"
  echo
}

ok()   { printf '%b\n' "${C_GREEN}✔${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}⚠${C_RESET} $*"; }
die()  { printf '%b\n' "${C_RED}✖ $*${C_RESET}"; exit 1; }

on_error() {
  local ec=$? line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}
  printf '\n%b\n' "${C_RED}${C_BOLD}Установка прервана${C_RESET}"
  echo "Код:     $ec"
  echo "Строка:  $line"
  echo "Команда: $cmd"
  echo "Лог:     $LOG_FILE"
  echo
  echo "Последние 40 строк:"
  tail -n 40 "$LOG_FILE" || true
  exit "$ec"
}
trap on_error ERR

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите скрипт от root на узле Proxmox."; }
require_proxmox() { command -v pct >/dev/null && command -v pvesm >/dev/null && command -v pveam >/dev/null || die "Это не похоже на узел Proxmox VE."; }

UI_BACKEND="text"

init_ui() {
  if command -v whiptail >/dev/null 2>&1; then
    UI_BACKEND="whiptail"
  elif command -v dialog >/dev/null 2>&1; then
    UI_BACKEND="dialog"
  else
    UI_BACKEND="text"
    warn "whiptail/dialog не найден. Будет использован текстовый режим."
  fi
}

ui_msg() {
  local title=$1 text=$2
  if [[ $UI_BACKEND == whiptail ]]; then
    whiptail --title "$title" --msgbox "$text" 22 100 >/dev/tty 2>&1
  elif [[ $UI_BACKEND == dialog ]]; then
    dialog --title "$title" --msgbox "$text" 22 100 >/dev/tty 2>&1
  else
    echo; echo "=== $title ==="; echo "$text"; echo
  fi
}

ui_yesno() {
  local title=$1 text=$2 default=${3:-yes}
  if [[ $UI_BACKEND == whiptail ]]; then
    local opt=()
    [[ $default == no ]] && opt+=(--defaultno)
    whiptail "${opt[@]}" --title "$title" --yesno "$text" 12 80 >/dev/tty 2>&1
  elif [[ $UI_BACKEND == dialog ]]; then
    local opt=()
    [[ $default == no ]] && opt+=(--defaultno)
    dialog "${opt[@]}" --title "$title" --yesno "$text" 12 80 >/dev/tty 2>&1
  else
    local ans suffix
    [[ $default == yes ]] && suffix="Y/n" || suffix="y/N"
    read -r -p "$text [$suffix]: " ans </dev/tty || true
    [[ -z $ans ]] && [[ $default == yes ]] && return 0
    [[ $ans =~ ^[YyДд]$ ]]
  fi
}

ui_input() {
  local __var=$1 title=$2 text=$3 def=$4 result=""
  if [[ $UI_BACKEND == whiptail ]]; then
    result=$(whiptail --output-fd 3 --title "$title" --inputbox "$text" 12 80 "$def" 3>&1 1>/dev/tty 2>/dev/tty) || die "Установка отменена."
  elif [[ $UI_BACKEND == dialog ]]; then
    result=$(dialog --output-fd 3 --title "$title" --inputbox "$text" 12 80 "$def" 3>&1 1>/dev/tty 2>/dev/tty) || die "Установка отменена."
  else
    read -r -p "$text [$def]: " result </dev/tty || true
    result=${result:-$def}
  fi
  printf -v "$__var" '%s' "$result"
}

ui_password() {
  local __var=$1 title=$2 text=$3 result=""
  if [[ $UI_BACKEND == whiptail ]]; then
    result=$(whiptail --output-fd 3 --title "$title" --passwordbox "$text" 12 80 3>&1 1>/dev/tty 2>/dev/tty) || die "Установка отменена."
  elif [[ $UI_BACKEND == dialog ]]; then
    result=$(dialog --output-fd 3 --title "$title" --passwordbox "$text" 12 80 3>&1 1>/dev/tty 2>/dev/tty) || die "Установка отменена."
  else
    read -r -s -p "$text: " result </dev/tty; echo >/dev/tty
  fi
  printf -v "$__var" '%s' "$result"
}

ui_menu() {
  local __var=$1 title=$2 text=$3; shift 3
  local items=("$@") result="" i
  ((${#items[@]} >= 2)) || die "Для меню '$title' нет вариантов."
  if [[ $UI_BACKEND == whiptail ]]; then
    result=$(whiptail --output-fd 3 --title "$title" --menu "$text" 24 110 14 "${items[@]}" 3>&1 1>/dev/tty 2>/dev/tty) || die "Установка отменена."
  elif [[ $UI_BACKEND == dialog ]]; then
    result=$(dialog --output-fd 3 --title "$title" --menu "$text" 24 110 14 "${items[@]}" 3>&1 1>/dev/tty 2>/dev/tty) || die "Установка отменена."
  else
    echo; echo "$title"; echo "$text"
    for ((i=0; i<${#items[@]}; i+=2)); do printf '  %d) %-18s %s\n' "$((i/2+1))" "${items[$i]}" "${items[$((i+1))]}"; done
    local choice
    read -r -p "Выбор [1]: " choice </dev/tty || true
    choice=${choice:-1}
    [[ $choice =~ ^[0-9]+$ ]] || die "Неверный выбор."
    i=$(( (choice-1)*2 ))
    (( i >= 0 && i < ${#items[@]} )) || die "Неверный выбор."
    result="${items[$i]}"
  fi
  printf -v "$__var" '%s' "$result"
}

human_kib() {
  local kib=${1:-0}
  numfmt --to=iec-i --suffix=B --from-unit=1024 "$kib" 2>/dev/null || echo "${kib} KiB"
}

storage_status_line() {
  local id=$1
  pvesm status --storage "$id" 2>/dev/null | awk -v id="$id" '$1==id {print}'
}

storage_cfg_block() {
  local id=$1
  awk -v target="$id" '
    /^[A-Za-z0-9_-]+: / {active=($2==target)}
    active {print}
  ' /etc/pve/storage.cfg 2>/dev/null
}

storage_backend_hint() {
  local id=$1 cfg type path vg thin pool
  cfg=$(storage_cfg_block "$id")
  type=$(awk 'NR==1{sub(":","",$1); print $1}' <<<"$cfg")
  path=$(awk '$1=="path"{print $2}' <<<"$cfg")
  vg=$(awk '$1=="vgname"{print $2}' <<<"$cfg")
  thin=$(awk '$1=="thinpool"{print $2}' <<<"$cfg")
  pool=$(awk '$1=="pool"{print $2}' <<<"$cfg")
  case "$type" in
    dir|nfs|cifs|cephfs) [[ -n $path ]] && echo "путь $path" || echo "файловое storage" ;;
    lvmthin) echo "LVM-thin ${vg:-?}/${thin:-?}" ;;
    lvm) echo "LVM ${vg:-?}" ;;
    zfspool) echo "ZFS ${pool:-?}" ;;
    *) echo "${type:-storage}" ;;
  esac
}

storage_menu() {
  local __var=$1 content=$2 title=$3 text=$4
  local line id type status total used avail pct desc
  local items=()
  while read -r line; do
    [[ -n $line ]] || continue
    read -r id type status total used avail pct <<<"$line"
    [[ $status == active ]] || continue
    desc="$type | свободно $(human_kib "$avail") из $(human_kib "$total") | $(storage_backend_hint "$id")"
    items+=("$id" "$desc")
  done < <(pvesm status --content "$content" --enabled 1 2>/dev/null | awk 'NR>1')
  ((${#items[@]})) || die "Нет активных Proxmox storage с поддержкой '$content'."
  ui_menu "$__var" "$title" "$text" "${items[@]}"
}

storage_details() {
  local id=$1 role=$2 line type status total used avail pct cfg content
  line=$(storage_status_line "$id")
  read -r _ type status total used avail pct <<<"$line"
  cfg=$(storage_cfg_block "$id")
  content=$(awk '$1=="content"{print $2}' <<<"$cfg")
  cat <<EOF
Назначение:   $role
Storage ID:   $id
Тип:          $type
Статус:       $status
Общий объём:  $(human_kib "$total")
Использовано: $(human_kib "$used")
Свободно:     $(human_kib "$avail")
Заполнение:   ${pct:-?}
Content:      ${content:-не указано}
Backend:      $(storage_backend_hint "$id")
EOF
}

show_disks_overview() {
  local text
  text="ФИЗИЧЕСКИЕ ДИСКИ УЗЛА:\n\n$(lsblk -d -o NAME,SIZE,MODEL,TYPE 2>/dev/null || true)\n\nPROXMOX STORAGE:\n\n$(pvesm status 2>/dev/null || true)\n\nУстановщик создаёт тома через Proxmox Storage Manager. Вы выбираете storage, а не /dev/sdX напрямую."
  ui_msg "Диски и хранилища" "$text"
}

next_ctid() { pvesh get /cluster/nextid 2>/dev/null || echo 200; }
randpass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}" || true; }
validate_int() { [[ $2 =~ ^[0-9]+$ ]] || die "$1 должно быть целым числом."; }

select_template() {
  ui_msg "Шаблон Debian" "Сейчас будет выбран storage только из тех, которые реально поддерживают content=vztmpl.\n\nЭто исправляет ошибку предыдущей версии, когда LVM-thin мог ошибочно попасть в список для шаблона."

  pveam update >/dev/null
  DEBIAN_TEMPLATE=$(pveam available --section system 2>/dev/null | awk '$1=="system" && $2 ~ /^debian-13-standard_/ {print $2; exit}')
  [[ -n $DEBIAN_TEMPLATE ]] || DEBIAN_TEMPLATE=$(pveam available --section system 2>/dev/null | awk '$1=="system" && $2 ~ /^debian-12-standard_/ {print $2; exit}')
  [[ -n $DEBIAN_TEMPLATE ]] || die "Не найден шаблон Debian 12/13. Проверьте pveam available."

  storage_menu TEMPLATE_STORAGE "vztmpl" "Шаблон Debian" "Куда скачать шаблон контейнера Debian?\n\nДля обычной установки чаще всего это storage 'local'."
  ui_msg "Выбран storage шаблона" "$(storage_details "$TEMPLATE_STORAGE" "Шаблон Debian")\n\nШаблон: $DEBIAN_TEMPLATE"

  local name="$DEBIAN_TEMPLATE"
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -Fq ":vztmpl/$name"; then
    echo "Скачиваю шаблон $name в $TEMPLATE_STORAGE ..."
    pveam download "$TEMPLATE_STORAGE" "$name"
  else
    ok "Шаблон Debian уже скачан"
  fi
  TEMPLATE_REF="$TEMPLATE_STORAGE:vztmpl/$name"
}

choose_size_gb() {
  local __var=$1 title=$2 text=$3 def=$4 storage=$5 value
  while true; do
    ui_input value "$title" "$text" "$def"
    validate_int "$title" "$value"
    (( value > 0 )) || { ui_msg "Ошибка" "Размер должен быть больше 0 GB."; continue; }
    local line avail avail_gb
    line=$(storage_status_line "$storage")
    avail=$(awk '{print $6}' <<<"$line")
    avail_gb=$(( avail / 1024 / 1024 ))
    if (( value > avail_gb )); then
      if ! ui_yesno "Мало места" "Вы запросили ${value} GB, а Proxmox показывает примерно ${avail_gb} GB свободно на '$storage'.\n\nПродолжить всё равно?\n\nДля thin storage это может быть осознанное over-provisioning." no; then
        continue
      fi
    fi
    printf -v "$__var" '%s' "$value"
    return
  done
}

collect_settings() {
  init_ui
  banner

  local action
  ui_menu action "Forgejo Installer v$VERSION" "Используйте ↑ ↓ для выбора и Enter для подтверждения." \
    "continue" "Начать настройку Forgejo" \
    "disks" "Показать физические диски и Proxmox storage"
  if [[ $action == disks ]]; then
    show_disks_overview
  fi

  local suggested_ctid; suggested_ctid=$(next_ctid)
  ui_input CTID "Контейнер" "CT ID нового контейнера Forgejo" "$suggested_ctid"
  ui_input HOSTNAME "Контейнер" "Hostname контейнера" "$DEFAULT_HOSTNAME"
  ui_input CORES "Ресурсы" "Количество CPU cores" "$DEFAULT_CORES"
  ui_input RAM "Ресурсы" "RAM в MB" "$DEFAULT_RAM"
  ui_input SWAP "Ресурсы" "Swap в MB" "$DEFAULT_SWAP"
  validate_int "CT ID" "$CTID"; validate_int "CPU" "$CORES"; validate_int "RAM" "$RAM"; validate_int "Swap" "$SWAP"
  pct status "$CTID" >/dev/null 2>&1 && die "Контейнер CT $CTID уже существует."

  show_disks_overview
  storage_menu ROOT_STORAGE "rootdir" "Системный диск Forgejo" "Выберите storage, где будет находиться ОС контейнера.\n\nЗдесь хранится Debian, Forgejo, PostgreSQL и системные файлы."
  ui_msg "Системное хранилище" "$(storage_details "$ROOT_STORAGE" "ОС контейнера Forgejo")"
  choose_size_gb ROOT_SIZE "Системный диск" "Размер системного диска LXC в GB.\n\nРекомендуется 24-32 GB." "$DEFAULT_DISK_GB" "$ROOT_STORAGE"

  SEPARATE_DATA=0
  DATA_STORAGE=""
  DATA_SIZE=""
  if ui_yesno "Git-данные" "Создать отдельный диск для репозиториев, вложений и Git LFS?\n\nРекомендуется: Да.\nТак Git-данные отделены от системного диска." yes; then
    SEPARATE_DATA=1
    storage_menu DATA_STORAGE "rootdir" "Диск данных Forgejo" "Выберите storage для Git-репозиториев и LFS.\n\nЭтот том будет подключён в контейнер как /var/lib/forgejo."
    ui_msg "Хранилище Git-данных" "$(storage_details "$DATA_STORAGE" "Репозитории Forgejo + LFS")"
    choose_size_gb DATA_SIZE "Диск Git-данных" "Размер диска репозиториев в GB.\n\nЕго можно будет увеличить позже через Proxmox." "$DEFAULT_DATA_GB" "$DATA_STORAGE"
  fi

  ui_input BRIDGE "Сеть" "Сетевой bridge Proxmox" "$DEFAULT_BRIDGE"
  if ui_yesno "Сеть" "Получать IPv4 по DHCP?" yes; then
    NET_IP="dhcp"; STATIC_IP=""; GATEWAY=""
  else
    ui_input STATIC_IP "Сеть" "IPv4 с маской, например 192.168.1.50/24" "192.168.1.50/24"
    ui_input GATEWAY "Сеть" "Gateway" "192.168.1.1"
    NET_IP="$STATIC_IP"
  fi

  local version_choice
  ui_menu version_choice "Версия Forgejo" "Выберите канал Forgejo." \
    "lts" "LTS ${DEFAULT_FORGEJO_LTS} | поддержка до 15.07.2027 | рекомендуется" \
    "stable" "Stable ${DEFAULT_FORGEJO_STABLE} | новые функции" \
    "manual" "Указать версию вручную"
  case "$version_choice" in
    lts) FORGEJO_VERSION="$DEFAULT_FORGEJO_LTS" ;;
    stable) FORGEJO_VERSION="$DEFAULT_FORGEJO_STABLE" ;;
    manual) ui_input FORGEJO_VERSION "Версия Forgejo" "Например 15.0.5" "$DEFAULT_FORGEJO_LTS" ;;
  esac

  ui_input ADMIN_USER "Администратор" "Имя администратора Forgejo" "admin"
  ui_input ADMIN_EMAIL "Администратор" "Email администратора" "admin@localhost.local"
  if ui_yesno "Пароль администратора" "Сгенерировать безопасный пароль автоматически?" yes; then
    ADMIN_PASS=$(randpass 20)
  else
    while true; do
      ui_password ADMIN_PASS "Пароль администратора" "Минимум 12 символов"
      ((${#ADMIN_PASS} >= 12)) && break
      ui_msg "Ошибка" "Пароль должен содержать минимум 12 символов."
    done
  fi

  DB_PASS=$(randpass 32)
  ALLOW_REG=0
  ui_yesno "Регистрация" "Разрешить пользователям самостоятельно регистрироваться в Forgejo?" no && ALLOW_REG=1

  select_template
}

summary() {
  local data_info
  if ((SEPARATE_DATA)); then
    data_info="$DATA_STORAGE / ${DATA_SIZE} GB / /var/lib/forgejo"
  else
    data_info="вместе с системным диском"
  fi

  local text
  text="ПАРАМЕТРЫ УСТАНОВКИ\n\nCT ID:              $CTID\nHostname:           $HOSTNAME\nCPU:                $CORES cores\nRAM:                $RAM MB\nSwap:               $SWAP MB\n\nСИСТЕМНЫЙ ДИСК:\n$ROOT_STORAGE / ${ROOT_SIZE} GB\n$(storage_backend_hint "$ROOT_STORAGE")\n\nGIT-ДАННЫЕ:\n$data_info\n\nШАБЛОН DEBIAN:\n$DEBIAN_TEMPLATE\nstorage: $TEMPLATE_STORAGE\n\nСЕТЬ:\nbridge: $BRIDGE\nIP: $NET_IP\n\nFORGEJO:\nверсия: $FORGEJO_VERSION\nadmin: $ADMIN_USER <$ADMIN_EMAIL>\nрегистрация: $([[ $ALLOW_REG -eq 1 ]] && echo разрешена || echo запрещена)"

  ui_yesno "Подтверждение установки" "$text\n\nНачать создание контейнера?" yes || exit 0
}

create_container() {
  echo; echo "[1/5] Создание LXC контейнера..."
  local net="name=eth0,bridge=${BRIDGE},ip=${NET_IP},type=veth"
  [[ $NET_IP != dhcp ]] && net+=",gw=${GATEWAY}"
  pct create "$CTID" "$TEMPLATE_REF" --hostname "$HOSTNAME" --cores "$CORES" --memory "$RAM" --swap "$SWAP" --rootfs "${ROOT_STORAGE}:${ROOT_SIZE}" --net0 "$net" --unprivileged 1 --onboot 1 --start 0
  if ((SEPARATE_DATA)); then pct set "$CTID" --mp0 "${DATA_STORAGE}:${DATA_SIZE},mp=/var/lib/forgejo,backup=1"; fi
  pct start "$CTID"
  sleep 4
  ok "LXC CT $CTID создан и запущен"
}

make_guest_installer() {
  local disable_reg=true
  ((ALLOW_REG)) && disable_reg=false
  cat > "$WORKDIR/guest-install.sh" <<GUEST_EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
FORGEJO_VERSION='${FORGEJO_VERSION}'
ADMIN_USER='${ADMIN_USER}'
ADMIN_EMAIL='${ADMIN_EMAIL}'
ADMIN_PASS='${ADMIN_PASS}'
DB_PASS='${DB_PASS}'
DISABLE_REGISTRATION='${disable_reg}'
HOSTNAME_VALUE='${HOSTNAME}'

apt-get update
apt-get install -y ca-certificates curl git git-lfs gnupg openssl postgresql openssh-server
systemctl enable --now postgresql ssh
getent group git >/dev/null 2>&1 || groupadd --system git
id -u git >/dev/null 2>&1 || useradd --system --gid git --home-dir /home/git --create-home --shell /bin/bash git
mkdir -p /var/lib/forgejo /var/lib/forgejo/data /var/lib/forgejo/custom /var/lib/forgejo/tmp /etc/forgejo /var/log/forgejo
# /var/lib/forgejo may be a dedicated ext4 mount containing root-owned lost+found.
# Never recursively chown the mount root, otherwise unprivileged LXC can fail on lost+found.
chown git:git /var/lib/forgejo
find /var/lib/forgejo -mindepth 1 -maxdepth 1 ! -name lost+found -exec chown -R git:git {} +
chown -R git:git /var/log/forgejo
chmod 750 /var/lib/forgejo
chown root:git /etc/forgejo
chmod 770 /etc/forgejo

ARCH=\$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
BIN="forgejo-\${FORGEJO_VERSION}-linux-\${ARCH}"
BASE="https://code.forgejo.org/forgejo/forgejo/releases/download/v\${FORGEJO_VERSION}"
curl -fL --retry 3 "\${BASE}/\${BIN}" -o /usr/local/bin/forgejo
chmod 755 /usr/local/bin/forgejo
if curl -fL --retry 2 "\${BASE}/\${BIN}.asc" -o /tmp/forgejo.asc; then
  if gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys EB114F5E6C0DC2BCDD183550A4B61A2DC5923710 >/dev/null 2>&1; then
    gpg --verify /tmp/forgejo.asc /usr/local/bin/forgejo
  else
    echo 'WARNING: GPG keyserver недоступен, подпись не проверена.' >&2
  fi
fi

systemctl start postgresql
# Do not use PostgreSQL DO $$ blocks here: this script is generated by an outer
# shell and then executed by an inner shell, so dollar quoting can be expanded
# to a PID. The generated DB password is strictly alphanumeric.
if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='forgejo'" | grep -q 1; then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER ROLE forgejo WITH LOGIN PASSWORD '${DB_PASS}';"
else
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE ROLE forgejo LOGIN PASSWORD '${DB_PASS}';"
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='forgejo'" | grep -q 1; then
  runuser -u postgres -- createdb -O forgejo -E UTF8 forgejo
fi

SECRET_KEY=\$(openssl rand -hex 32)
cat > /etc/forgejo/app.ini <<INI_EOF
APP_NAME = Forgejo
RUN_USER = git
RUN_MODE = prod
WORK_PATH = /var/lib/forgejo

[repository]
ROOT = /var/lib/forgejo/data/forgejo-repositories

[database]
DB_TYPE = postgres
HOST = 127.0.0.1:5432
NAME = forgejo
USER = forgejo
PASSWD = ${DB_PASS}
SSL_MODE = disable

[server]
DOMAIN = \${HOSTNAME_VALUE}
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
ROOT_URL = http://\${HOSTNAME_VALUE}:3000/
SSH_DOMAIN = \${HOSTNAME_VALUE}
SSH_PORT = 22
START_SSH_SERVER = false
LFS_START_SERVER = true
OFFLINE_MODE = false

[service]
DISABLE_REGISTRATION = \${DISABLE_REGISTRATION}
REQUIRE_SIGNIN_VIEW = false

[security]
INSTALL_LOCK = true
SECRET_KEY = \${SECRET_KEY}

[log]
MODE = console
LEVEL = Info
ROOT_PATH = /var/log/forgejo
INI_EOF
chown root:git /etc/forgejo/app.ini
chmod 640 /etc/forgejo/app.ini

cat > /etc/systemd/system/forgejo.service <<'UNIT_EOF'
[Unit]
Description=Forgejo Git Service
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
Restart=always
RestartSec=2s
User=git
Group=git
WorkingDirectory=/var/lib/forgejo
Environment=USER=git
Environment=HOME=/home/git
Environment=FORGEJO_WORK_DIR=/var/lib/forgejo
ExecStart=/usr/local/bin/forgejo web --config /etc/forgejo/app.ini

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now forgejo
for i in {1..30}; do curl -fsS http://127.0.0.1:3000/ >/dev/null 2>&1 && break; sleep 1; done
if ! runuser -u git -- /usr/local/bin/forgejo --work-path /var/lib/forgejo --config /etc/forgejo/app.ini admin user list 2>/dev/null | grep -q "${ADMIN_USER}"; then
  runuser -u git -- /usr/local/bin/forgejo --work-path /var/lib/forgejo --config /etc/forgejo/app.ini admin user create --username "${ADMIN_USER}" --password "${ADMIN_PASS}" --email "${ADMIN_EMAIL}" --admin --must-change-password=false
fi
systemctl restart forgejo
systemctl is-active --quiet forgejo
/usr/local/bin/forgejo --version
GUEST_EOF
  chmod 700 "$WORKDIR/guest-install.sh"
}

install_forgejo() {
  echo "[2/5] Подготовка установщика Forgejo..."
  make_guest_installer
  pct push "$CTID" "$WORKDIR/guest-install.sh" /root/forgejo-install.sh --perms 700
  echo "[3/5] Установка Forgejo и PostgreSQL..."
  pct exec "$CTID" -- bash /root/forgejo-install.sh
  ok "Forgejo установлен"
}

get_ip() {
  local ip=""
  for _ in {1..20}; do
    ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.' || true)
    [[ -n $ip ]] && break
    sleep 1
  done
  echo "$ip"
}

finish() {
  echo "[4/5] Проверка сервисов..."
  pct exec "$CTID" -- systemctl is-active --quiet forgejo
  pct exec "$CTID" -- systemctl is-active --quiet postgresql
  local ip; ip=$(get_ip)
  echo "[5/5] Готово"; echo
  printf '%b\n' "${C_GREEN}${C_BOLD}Forgejo успешно установлен.${C_RESET}"
  echo "CT ID:        $CTID"
  echo "Hostname:     $HOSTNAME"
  [[ -n $ip ]] && echo "Web:          http://$ip:3000" || echo "Web:          http://$HOSTNAME:3000"
  echo "SSH Git:      порт 22 контейнера"
  echo "Admin:        $ADMIN_USER"
  echo "Password:     $ADMIN_PASS"
  echo
  echo "Сохраните пароль сейчас. Он также присутствует в логе установки: $LOG_FILE"
  echo "Статус:       pct exec $CTID -- systemctl status forgejo"
  echo "Логи Forgejo: pct exec $CTID -- journalctl -u forgejo -n 100 --no-pager"
}

main() {
  require_root
  require_proxmox
  collect_settings
  summary
  create_container
  install_forgejo
  finish
}
main "$@"
