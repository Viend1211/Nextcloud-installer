# Nextcloud Installer & Manager для Proxmox VE

## v0.4.3 RU

Исправлена ошибка:

```text
width: unbound variable
```

Причина была в Bash-конструкции, где переменная `width` объявлялась и использовалась
в одном выражении при включённом `set -u`.

Исправлены оба найденных места:
- `maintenance/storage-migrator.sh`
- `lib/common.sh`

Также обработчик ошибок мигратора теперь показывает:
- этап;
- код ошибки;
- строку;
- фактическую команду;
- последние 50 строк своего лога.

## Запуск

После загрузки файлов в GitHub:

```bash
rm -rf /tmp/nextcloud-installer /tmp/nextcloud-install.sh
curl -fsSL "https://raw.githubusercontent.com/Viend1211/Nextcloud-installer/main/install.sh?nocache=$(date +%s)" -o /tmp/nextcloud-install.sh
grep VERSION /tmp/nextcloud-install.sh
bash /tmp/nextcloud-install.sh
```

Ожидаемая версия:

```text
VERSION="0.4.3"
```
