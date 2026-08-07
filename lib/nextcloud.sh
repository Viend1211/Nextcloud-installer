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
  configure_defaults
  select_pve_storage
  select_data_disk
  choose_network

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

Start installation?"; then
    exit 0
  fi

  perform_install
}

advanced_install() {
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
Upload limit: $UPLOAD_LIMIT

Start installation?"; then
    exit 0
  fi

  perform_install
}

perform_install() {
  ADMIN_PASS="$(randpass)"
  DB_PASS="$(randpass)"

  create_lxc
  install_nextcloud_inside_lxc
  show_result
}

install_nextcloud_inside_lxc() {
  local inner="/tmp/nc-inner-$CTID.sh"
  local data_dir="/var/www/nextcloud/data"
  [[ -n "${DATA_MOUNT:-}" ]] && data_dir="/mnt/data/data"

  cat > "$inner" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

DB_ENGINE="$DB_ENGINE"
DB_PASS="$DB_PASS"
ADMIN_USER="$ADMIN_USER"
ADMIN_PASS="$ADMIN_PASS"
DATA_DIR="$data_dir"
IP="$CONTAINER_IP"
UPLOAD_LIMIT="$UPLOAD_LIMIT"

apt-get update
apt-get upgrade -y

COMMON="nginx redis-server curl ca-certificates unzip cron imagemagick ffmpeg \
php-fpm php-cli php-common php-gd php-curl php-mbstring php-intl php-gmp \
php-bcmath php-xml php-zip php-apcu php-redis php-imagick"

if [[ "\$DB_ENGINE" == "postgresql" ]]; then
  apt-get install -y \$COMMON postgresql php-pgsql
else
  apt-get install -y \$COMMON mariadb-server php-mysql
fi

systemctl enable --now redis-server nginx cron

PHPVER="\$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHPINI="/etc/php/\${PHPVER}/fpm/php.ini"
sed -i "s/^memory_limit = .*/memory_limit = 512M/" "\$PHPINI"
sed -i "s/^upload_max_filesize = .*/upload_max_filesize = \$UPLOAD_LIMIT/" "\$PHPINI"
sed -i "s/^post_max_size = .*/post_max_size = \$UPLOAD_LIMIT/" "\$PHPINI"
sed -i "s/^max_execution_time = .*/max_execution_time = 3600/" "\$PHPINI"

cat > "/etc/php/\${PHPVER}/fpm/conf.d/99-nextcloud.ini" <<'PHP'
opcache.enable=1
opcache.enable_cli=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
PHP

systemctl restart "php\${PHPVER}-fpm"

if [[ "\$DB_ENGINE" == "postgresql" ]]; then
  systemctl enable --now postgresql
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
CREATE USER nextcloud WITH PASSWORD '\$DB_PASS';
CREATE DATABASE nextcloud OWNER nextcloud TEMPLATE template0 ENCODING 'UTF8';
SQL
  DB_TYPE="pgsql"
else
  systemctl enable --now mariadb
  mysql <<SQL
CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'nextcloud'@'localhost' IDENTIFIED BY '\$DB_PASS';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
SQL
  DB_TYPE="mysql"
fi

curl -fL --retry 5 https://download.nextcloud.com/server/releases/latest.zip -o /tmp/nextcloud.zip
unzip -q /tmp/nextcloud.zip -d /tmp
rm -rf /var/www/nextcloud
mv /tmp/nextcloud /var/www/nextcloud
mkdir -p "\$DATA_DIR"
chown -R www-data:www-data /var/www/nextcloud "\$DATA_DIR"

PHP_SOCK="/run/php/php\${PHPVER}-fpm.sock"

cat > /etc/nginx/sites-available/nextcloud <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/nextcloud;
    index index.php index.html /index.php\$request_uri;
    client_max_body_size \$UPLOAD_LIMIT;

    location = /robots.txt { allow all; log_not_found off; access_log off; }

    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav { return 301 /remote.php/dav/; }
        return 301 /index.php\$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:\$|/) { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }

    location ~ \.php(?:\$|/) {
        rewrite ^/(?!index|remote|public|cron|core/ajax/update|status|ocs/v[12]|updater/.+|ocs-provider/.+) /index.php\$request_uri;
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        set \$path_info \$fastcgi_path_info;
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass unix:\$PHP_SOCK;
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
systemctl reload nginx

cd /var/www/nextcloud
occ(){ runuser -u www-data -- php occ "\$@"; }

occ maintenance:install \
  --database="\$DB_TYPE" \
  --database-name=nextcloud \
  --database-user=nextcloud \
  --database-pass="\$DB_PASS" \
  --admin-user="\$ADMIN_USER" \
  --admin-pass="\$ADMIN_PASS" \
  --data-dir="\$DATA_DIR"

occ config:system:set trusted_domains 0 --value=localhost
occ config:system:set trusted_domains 1 --value="\$IP"
occ config:system:set overwrite.cli.url --value="http://\$IP"
occ config:system:set memcache.local --value='\OC\Memcache\APCu'
occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
occ config:system:set redis host --value=127.0.0.1
occ config:system:set redis port --type=integer --value=6379
occ background:cron
occ config:system:set maintenance_window_start --type=integer --value=1 || true

cat > /etc/cron.d/nextcloud <<'CRON'
*/5 * * * * www-data php -f /var/www/nextcloud/cron.php
CRON
chmod 644 /etc/cron.d/nextcloud

systemctl restart "php\${PHPVER}-fpm" nginx redis-server cron
rm -f /tmp/nextcloud.zip
EOF

  chmod +x "$inner"
  pct push "$CTID" "$inner" /root/install-nextcloud-inner.sh --perms 0755
  pct exec "$CTID" -- bash /root/install-nextcloud-inner.sh
  rm -f "$inner"
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

IMPORTANT:
Save these passwords now.
For permanent use, reserve $CONTAINER_IP in DHCP or configure a static IP.
Add HTTPS/reverse proxy before exposing Nextcloud to the Internet.
============================================================
EOF
}
