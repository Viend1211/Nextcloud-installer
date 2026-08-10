# Nextcloud Installer & Manager для Proxmox VE

## v0.4.2 RU

Исправление запуска визуального интерфейса.

### Исправлено

- `animated_splash: command not found`:
  функция анимации теперь объявляется до первого вызова.
- Новый запуск больше не смешивается со старым `/var/log/nextcloud-installer.log`.
- Предыдущий лог сохраняется рядом с датой и временем:
  `/var/log/nextcloud-installer.log.YYYYMMDD-HHMMSS.previous`.
- Текущий лог начинается с чистого файла.
- Обработчик ошибок показывает только строки текущего запуска.
- Версия всех основных модулей обновлена до `0.4.2`.

### Запуск свежей версии после загрузки в GitHub

```bash
rm -rf /tmp/nextcloud-installer /tmp/nextcloud-install.sh
curl -fsSL "https://raw.githubusercontent.com/Viend1211/Nextcloud-installer/main/install.sh?nocache=$(date +%s)" -o /tmp/nextcloud-install.sh
grep VERSION /tmp/nextcloud-install.sh
bash /tmp/nextcloud-install.sh
```

Перед запуском должно отображаться:

```text
VERSION="0.4.2"
```
