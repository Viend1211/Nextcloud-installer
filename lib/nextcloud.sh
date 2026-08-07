#!/usr/bin/env bash

choose_database() {
  DB_ENGINE="$(menu "Database" "Choose database engine:" \
    postgresql "PostgreSQL (recommended)" \
    mariadb "MariaDB")"
}

configure_defaults() {
  CTID="$(get_next_ctid)"
  HOSTNAME="nextcloud"
  CORES="2"
  MEMORY_MB="4096"
  SWAP_MB="1024"
  ROOTFS_GB="20"
  ADMIN_USER="admin"
  UPLOAD_LIMIT="10G"
  DB_ENGINE="postgresql"
}

quick_install() {
  INSTALL_MODE="quick"
  configure_defaults
  select_pve_storage
  select_data_disk
  choose_network
  choose_remote_access

  if ! yesno "Ready to install" \
"Quick install configuration:

CT ID: $CTID
Hostname: $HOSTNAME
CPU: $CORES
RAM: $MEMORY_MB MB
System disk: $ROOTFS_GB GB on $SYSTEM_STORAGE
Data disk: ${DATA_DISK:-inside LXC}
Database: PostgreSQL
Network: $NETCONF
Remote access: ${REMOTE_MODE:-local}
Public IP: ${PUBLIC_IP:-not added}
Custom host: ${CUSTOM_REMOTE_HOST:-not added}

Start installation?"; then
    exit 0
  fi

  perform_install
}

advanced_install() {
  INSTALL_MODE="advanced"
  configure_defaults

  CTID="$(input "CT ID" "LXC container ID:" "$CTID")"
  HOSTNAME="$(input "Hostname" "Container hostname:" "$HOSTNAME")"
  CORES="$(input "CPU" "CPU cores:" "$CORES")"
  MEMORY_MB="$(input "RAM" "RAM in MB:" "$MEMORY_MB")"
  SWAP_MB="$(input "Swap" "Swap in MB:" "$SWAP_MB")"
  ROOTFS_GB="$(input "System disk" "LXC system disk size in GB:" "$ROOTFS_GB")"
  ADMIN_USER="$(input "Nextcloud admin" "Administrator username:" "$ADMIN_USER")"
  UPLOAD_LIMIT="$(input "Upload limit" "Maximum upload size, e.g. 10G:" "$UPLOAD_LIMIT")"

  select_pve_storage
  select_data_disk
  choose_database
  choose_network
  choose_remote_access

  if ! yesno "Ready to install" \
"Advanced configuration:

CT ID: $CTID
Hostname: $HOSTNAME
CPU: $CORES
RAM: $MEMORY_MB MB
Swap: $SWAP_MB MB
System: $ROOTFS_GB GB on $SYSTEM_STORAGE
Data: ${DATA_DISK:-inside LXC}
Database: $DB_ENGINE
Network: $NETCONF
Remote access: ${REMOTE_MODE:-local}
Public IP: ${PUBLIC_IP:-not added}
Custom host: ${CUSTOM_REMOTE_HOST:-not added}
Upload limit: $UPLOAD_LIMIT

Start installation?"; then
    exit 0
  fi

  perform_install
}

perform_install() {
  ADMIN_PASS="$(randpass)"
  DB_PASS="$(randpass)"

  TOTAL_STEPS=10
  STEP_NO=0
  progress_header

  step "Final safety checks"
  log_text "System storage: $SYSTEM_STORAGE"
  log_text "Data disk: ${DATA_DISK:-inside LXC}"
  log_text "Network: $NETCONF"
  pveversion | tee -a "$LOG_FILE"
  pvesm status | tee -a "$LOG_FILE"

  step "Preparing Proxmox storage and Debian template"
  download_debian_template

  step "Creating LXC container"
  create_lxc_only

  step "Starting LXC and waiting for network"
  start_lxc_and_wait

  step "Updating Debian inside LXC"
  pct exec "$CTID" -- bash -lc \
    'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get upgrade -y' \
    2>&1 | tee -a "$LOG_FILE"
  test ${PIPESTATUS[0]} -eq 0

  step "Installing web server, PHP, Redis and database"
  install_nextcloud_packages

  step "Creating and configuring database"
  configure_nextcloud_database

  step "Downloading and unpacking Nextcloud"
  download_and_unpack_nextcloud

  step "Configuring Nginx, PHP and Nextcloud"
  configure_nextcloud_application

  step "Running final service checks"
  final_service_checks

  step "Installation completed"
  show_result
}

create_lxc_only() {
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
    --features keyctl=1,nesting=1 \
    2>&1 | tee -a "$LOG_FILE"
  test ${PIPESTATUS[0]} -eq 0

  if [[ -n "${DATA_MOUNT:-}" ]]; then
    pct set "$CTID" -mp0 "$DATA_MOUNT,mp=/mnt/data" \
      2>&1 | tee -a "$LOG_FILE"
    test ${PIPESTATUS[0]} -eq 0
  fi
}

start_lxc_and_wait() {
  pct start "$CTID" 2>&1 | tee -a "$LOG_FILE"
  test ${PIPESTATUS[0]} -eq 0

  CONTAINER_IP=""
  for i in $(seq 1 75); do
    printf '\rWaiting for IP... %d/75' "$i"
    CONTAINER_IP="$(pct exec "$CTID" -- bash -lc "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)"
    if [[ -n "$CONTAINER_IP" ]]; then
      echo
      log_text "Container IP: $CONTAINER_IP"
      return 0
    fi
    sleep 2
  done
  echo
  die "LXC started but did not get an IP address."
}

write_inner_env() {
  local data_dir="/var/www/nextcloud/data"
  [[ -n "${DATA_MOUNT:-}" ]] && data_dir="/mnt/data/data"

  cat > "/tmp/nc-env-$CTID" <<EOF
DB_ENGINE='$DB_ENGINE'
DB_PASS='$DB_PASS'
ADMIN_USER='$ADMIN_USER'
ADMIN_PASS='$ADMIN_PASS'
DATA_DIR='$data_dir'
IP='$CONTAINER_IP'
UPLOAD_LIMIT='$UPLOAD_LIMIT'
PUBLIC_IP='${PUBLIC_IP:-}'
CUSTOM_REMOTE_HOST='${CUSTOM_REMOTE_HOST:-}'
REMOTE_MODE='${REMOTE_MODE:-local}'
EOF

  pct push "$CTID" "/tmp/nc-env-$CTID" /root/nc-installer.env --perms 0600
  rm -f "/tmp/nc-env-$CTID"
}

install_nextcloud_packages() {
  write_inner_env

  pct exec "$CTID" -- bash -lc '
    set -Eeuo pipefail
    source /root/nc-installer.env
    export DEBIAN_FRONTEND=noninteractive

    COMMON="nginx redis-server curl ca-certificates unzip cron imagemagick ffmpeg \
php-fpm php-cli php-common php-gd php-curl php-mbstring php-intl php-gmp \
php-bcmath php-xml php-zip php-apcu php-redis php-imagick"

    if [[ "$DB_ENGINE" == "postgresql" ]]; then
      apt-get install -y $COMMON postgresql php-pgsql
      systemctl enable --now postgresql
    else
      apt-get install -y $COMMON mariadb-server php-mysql
      systemctl enable --now mariadb
    fi

    systemctl enable --now redis-server nginx cron
  ' 2>&1 | tee -a "$LOG_FILE"
  test ${PIPESTATUS[0]} -eq 0
}

configure_nextcloud_database() {
  pct exec "$CTID" -- bash -lc '
    set -Eeuo pipefail
    source /root/nc-installer.env

    if [[ "$DB_ENGINE" == "postgresql" ]]; then
      runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
CREATE USER nextcloud WITH PASSWORD '"'"'$DB_PASS'"'"';
CREATE DATABASE nextcloud OWNER nextcloud TEMPLATE template0 ENCODING '"'"'UTF8'"'"';
SQL
    else
      mysql <<SQL
CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '"'"'nextcloud'"'"'@'"'"'localhost'"'"' IDENTIFIED BY '"'"'$DB_PASS'"'"';
GRANT ALL PRIVILEGES ON nextcloud.* TO '"'"'nextcloud'"'"'@'"'"'localhost'"'"';
FLUSH PRIVILEGES;
SQL
    fi
  ' 2>&1 | tee -a "$LOG_FILE"
  test ${PIPESTATUS[0]} -eq 0
}

download_and_unpack_nextcloud() {
  pct exec "$CTID" -- bash -lc '
    set -Eeuo pipefail
    source /root/nc-installer.env

    rm -f /tmp/nextcloud.zip
    rm -rf /tmp/nextcloud
    curl -fL --retry 5 --retry-delay 3 \
      https://download.nextcloud.com/server/releases/latest.zip \
      -o /tmp/nextcloud.zip

    unzip -q /tmp/nextcloud.zip -d /tmp
    rm -rf /var/www/nextcloud
    mv /tmp/nextcloud /var/www/nextcloud

    mkdir -p "$DATA_DIR"
    chown -R www-data:www-data /var/www/nextcloud "$DATA_DIR"
  ' 2>&1 | tee -a "$LOG_FILE"
  test ${PIPESTATUS[0]} -eq 0
}

configure_nextcloud_application() {
  pct exec "$CTID" -- bash -lc '
    set -Eeuo pipefail
    source /root/nc-installer.env

    PHPVER="$(php -r '\''echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;'\'')"
    PHPINI="/etc/php/${PHPVER}/fpm/php.ini"

    sed -i "s/^memory_limit = .*/memory_limit = 512M/" "$PHPINI"
    sed -i "s/^upload_max_filesize = .*/upload_max_filesize = $UPLOAD_LIMIT/" "$PHPINI"
    sed -i "s/^post_max_size = .*/post_max_size = $UPLOAD_LIMIT/" "$PHPINI"
    sed -i "s/^max_execution_time = .*/max_execution_time = 3600/" "$PHPINI"

    cat > "/etc/php/${PHPVER}/fpm/conf.d/99-nextcloud.ini" <<PHP
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
PHP

    PHP_SOCK="/run/php/php${PHPVER}-fpm.sock"

    cat > /etc/nginx/sites-available/nextcloud <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/nextcloud;
    index index.php index.html /index.php\$request_uri;
    client_max_body_size $UPLOAD_LIMIT;

    location = /robots.txt { allow all; log_not_found off; access_log off; }

    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav { return 301 /remote.php/dav/; }
        return 301 /index.php\$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:\$|/) { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }

    location ~ \.php(?:\$|/) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass unix:$PHP_SOCK;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
    }

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }
}
NGINX

    rm -f /etc/nginx/sites-enabled/default
    ln -sfn /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud

    nginx -t
    systemctl restart "php${PHPVER}-fpm"
    systemctl reload nginx

    cd /var/www/nextcloud
    occ(){ runuser -u www-data -- php occ "$@"; }

    if [[ "$DB_ENGINE" == "postgresql" ]]; then
      DB_TYPE="pgsql"
    else
      DB_TYPE="mysql"
    fi

    occ maintenance:install \
      --database="$DB_TYPE" \
      --database-name=nextcloud \
      --database-user=nextcloud \
      --database-pass="$DB_PASS" \
      --admin-user="$ADMIN_USER" \
      --admin-pass="$ADMIN_PASS" \
      --data-dir="$DATA_DIR"

    occ config:system:set trusted_domains 0 --value=localhost
    occ config:system:set trusted_domains 1 --value="$IP"

    TRUSTED_INDEX=2
    if [[ -n "${PUBLIC_IP:-}" ]]; then
      occ config:system:set trusted_domains "$TRUSTED_INDEX" --value="$PUBLIC_IP"
      TRUSTED_INDEX=$((TRUSTED_INDEX + 1))
    fi

    if [[ -n "${CUSTOM_REMOTE_HOST:-}" ]]; then
      occ config:system:set trusted_domains "$TRUSTED_INDEX" --value="$CUSTOM_REMOTE_HOST"
    fi

    # Keep CLI URL local until HTTPS/reverse proxy is explicitly configured.
    occ config:system:set overwrite.cli.url --value="http://$IP"
    occ config:system:set memcache.local --value='\''\OC\Memcache\APCu'\''
    occ config:system:set memcache.distributed --value='\''\OC\Memcache\Redis'\''
    occ config:system:set memcache.locking --value='\''\OC\Memcache\Redis'\''
    occ config:system:set redis host --value=127.0.0.1
    occ config:system:set redis port --type=integer --value=6379
    occ background:cron
    occ config:system:set maintenance_window_start --type=integer --value=1 || true

    cat > /etc/cron.d/nextcloud <<CRON
*/5 * * * * www-data php -f /var/www/nextcloud/cron.php
CRON
    chmod 644 /etc/cron.d/nextcloud

    systemctl restart "php${PHPVER}-fpm" nginx redis-server cron
  ' 2>&1 | tee -a "$LOG_FILE"
  test ${PIPESTATUS[0]} -eq 0
}

final_service_checks() {
  pct exec "$CTID" -- bash -lc '
    set -Eeuo pipefail
    systemctl is-active --quiet nginx
    systemctl is-active --quiet redis-server
    systemctl is-active --quiet cron

    if systemctl list-unit-files | grep -q "^postgresql.service"; then
      systemctl is-active --quiet postgresql
    fi

    if systemctl list-unit-files | grep -q "^mariadb.service"; then
      systemctl is-active --quiet mariadb
    fi

    cd /var/www/nextcloud
    runuser -u www-data -- php occ status
  ' 2>&1 | tee -a "$LOG_FILE"
  test ${PIPESTATUS[0]} -eq 0
}

show_result() {
  cat <<EOF

============================================================
 NEXTCLOUD INSTALLATION COMPLETE
============================================================

URL:                 http://$CONTAINER_IP
LXC ID:              $CTID
Hostname:            $HOSTNAME

Nextcloud admin:     $ADMIN_USER
Nextcloud password:  $ADMIN_PASS

LXC root password:   $LXC_ROOT_PASS

Database:            $DB_ENGINE
Database user:       nextcloud
Database password:   $DB_PASS

System storage:      $SYSTEM_STORAGE
System disk:         $ROOTFS_GB GB
Data disk:           ${DATA_DISK:-inside LXC}
Data mount:          ${DATA_MOUNT:-inside LXC}

Local URL:             http://$CONTAINER_IP
Public IPv4:           ${PUBLIC_IP:-not added}
Custom trusted host:   ${CUSTOM_REMOTE_HOST:-not added}

IMPORTANT:
Save these passwords now.
For permanent use, reserve $CONTAINER_IP in DHCP or configure a static IP.
If you use the public IPv4 with the current HTTP-only setup, forward
TCP 80 on the router to the Nextcloud container only for testing.
For permanent Internet access, configure HTTPS and use TCP 443.

Add HTTPS/reverse proxy before exposing Nextcloud permanently to the Internet.
============================================================
EOF
}
