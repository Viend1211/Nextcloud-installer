#!/usr/bin/env bash
set -Eeuo pipefail

admin_select_ct() {
  local opts=()
  while read -r id status name; do
    [[ "$id" == "VMID" ]] && continue
    opts+=("$id" "$status | $name")
  done < <(pct list)
  [[ ${#opts[@]} -gt 0 ]] || { msg "Контейнеры" "LXC-контейнеры не найдены."; return 1; }
  ADMIN_CTID="$(menu "Выбор контейнера" "Выберите контейнер Nextcloud:" "${opts[@]}")"
}

occ() {
  pct exec "$ADMIN_CTID" -- bash -lc "cd /var/www/nextcloud && runuser -u www-data -- php occ $*"
}

next_trusted_index() {
  pct exec "$ADMIN_CTID" -- bash -lc \
    "cd /var/www/nextcloud && runuser -u www-data -- php occ config:system:get trusted_domains" 2>/dev/null |
    sed '/^[[:space:]]*$/d' | wc -l
}

domains_menu() {
  while true; do
    local a
    a="$(menu "Домены и внешний доступ" "Выберите действие:" \
      show "Показать текущие разрешённые адреса" \
      auto "Автоматически определить внешний IPv4 и добавить" \
      ip "Добавить IP-адрес" \
      domain "Добавить доменное имя" \
      remove "Удалить запись из trusted_domains" \
      back "Назад")" || return 0

    case "$a" in
      show) occ "config:system:get trusted_domains"; echo; read -r -p "Нажмите Enter..." ;;
      auto)
        local ext idx
        ext="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
        if [[ "$ext" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
          if yesno "Внешний IP" "Найден внешний IPv4:

$ext

Добавить его в trusted_domains?"; then
            idx="$(next_trusted_index)"
            occ "config:system:set trusted_domains $idx --value='$ext'"
            msg "Готово" "Внешний IP добавлен: $ext"
          fi
        else
          msg "Ошибка" "Не удалось определить внешний IPv4."
        fi
        ;;
      ip)
        local v idx
        v="$(input "Добавить IP" "Введите IP-адрес:" "")"
        [[ -z "$v" ]] && continue
        idx="$(next_trusted_index)"
        occ "config:system:set trusted_domains $idx --value='$v'"
        msg "Готово" "IP добавлен."
        ;;
      domain)
        local v idx
        v="$(input "Добавить домен" "Введите домен, например cloud.example.ru:" "")"
        [[ -z "$v" ]] && continue
        idx="$(next_trusted_index)"
        occ "config:system:set trusted_domains $idx --value='$v'"
        msg "Готово" "Домен добавлен."
        ;;
      remove)
        local opts=() i=0 v sel
        while IFS= read -r v; do
          [[ -z "$v" ]] && continue
          opts+=("$i" "$v"); i=$((i+1))
        done < <(occ "config:system:get trusted_domains")
        [[ ${#opts[@]} -eq 0 ]] && { msg "Список" "Записей нет."; continue; }
        sel="$(menu "Удаление адреса" "Выберите запись:" "${opts[@]}")" || continue
        yesno "Подтверждение" "Удалить выбранную запись?" && occ "config:system:delete trusted_domains $sel"
        ;;
      *) return 0 ;;
    esac
  done
}

admin_nextcloud_occ() {
  admin_select_ct || return 0
  while true; do
    local a
    a="$(menu "Настройки Nextcloud" "Выберите действие:" \
      status "Показать состояние" \
      users "Показать пользователей" \
      reset "Сбросить пароль пользователя" \
      domains "Домены, IP и внешний доступ" \
      scan "Пересканировать файлы" \
      repair "Восстановление Nextcloud" \
      maintenance "Режим обслуживания" \
      back "Назад")" || return 0
    case "$a" in
      status) occ status; echo; read -r -p "Нажмите Enter..." ;;
      users) occ user:list; echo; read -r -p "Нажмите Enter..." ;;
      reset)
        local u; u="$(input "Сброс пароля" "Пользователь:" "admin")"
        [[ -n "$u" ]] && occ "user:resetpassword '$u'"
        ;;
      domains) domains_menu ;;
      scan) yesno "Сканирование" "Пересканировать все файлы?" && occ "files:scan --all" ;;
      repair) yesno "Восстановление" "Запустить maintenance:repair?" && occ maintenance:repair ;;
      maintenance)
        local mode
        mode="$(menu "Режим обслуживания" "Выберите:" on "Включить" off "Выключить")" || continue
        [[ "$mode" == on ]] && occ "maintenance:mode --on" || occ "maintenance:mode --off"
        ;;
      *) return 0 ;;
    esac
  done
}

admin_container_tools() {
  admin_select_ct || return 0
  while true; do
    local a
    a="$(menu "Управление LXC" "Выберите действие:" \
      enter "Открыть консоль контейнера" \
      rootpass "Сбросить пароль root" \
      config "Показать конфигурацию" \
      ip "Показать IP" \
      disk "Показать использование дисков" \
      start "Запустить контейнер" \
      stop "Остановить контейнер" \
      restart "Перезапустить контейнер" \
      back "Назад")" || return 0
    case "$a" in
      enter) pct enter "$ADMIN_CTID" ;;
      rootpass) pct exec "$ADMIN_CTID" -- passwd root ;;
      config) pct config "$ADMIN_CTID"; echo; read -r -p "Нажмите Enter..." ;;
      ip) pct exec "$ADMIN_CTID" -- hostname -I; echo; read -r -p "Нажмите Enter..." ;;
      disk) pct exec "$ADMIN_CTID" -- df -hT; echo; read -r -p "Нажмите Enter..." ;;
      start) pct start "$ADMIN_CTID"; msg "Готово" "Контейнер запущен." ;;
      stop) yesno "Остановка" "Остановить контейнер?" && pct stop "$ADMIN_CTID" ;;
      restart) yesno "Перезапуск" "Перезапустить контейнер?" && pct reboot "$ADMIN_CTID" ;;
      *) return 0 ;;
    esac
  done
}

admin_diagnostics() {
  clear || true
  echo "=== Диагностика Proxmox / Nextcloud ==="
  echo; pveversion || true
  echo; pct list || true
  echo; pvesm status || true
  echo; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL || true
  echo; df -hT || true
  echo; zpool status 2>/dev/null || true
  echo; cat /proc/mdstat 2>/dev/null || true
  echo; read -r -p "Нажмите Enter..."
}
