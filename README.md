# Nextcloud Installer for Proxmox VE

## v0.1.1

Исправлено:
- корректное определение активных Proxmox storage с поддержкой `rootdir`;
- совместимость парсинга `pvesm status` с Proxmox VE 9;
- автоматический выбор активного storage с поддержкой `vztmpl` для Debian LXC template;
- при ошибке определения storage установщик теперь печатает `pvesm status` и `/etc/pve/storage.cfg` для диагностики.


Интерактивный установщик **Nextcloud в LXC на Proxmox VE**.

Проект рассчитан на сценарий, где сама система Nextcloud находится на хранилище Proxmox, а пользовательские файлы при необходимости размещаются на отдельном физическом HDD/SSD.

> ⚠️ Проект находится на ранней стадии. Перед использованием на важных данных обязательно сделайте резервные копии.

## Возможности

- Quick Install для быстрой установки с разумными параметрами.
- Advanced Install для ручного выбора CPU, RAM, swap, размера системного диска, сети и БД.
- Автоматическое создание unprivileged LXC.
- Автоматическая загрузка Debian LXC template.
- Nextcloud + Nginx + PHP-FPM + Redis.
- Выбор PostgreSQL или MariaDB.
- Выбор Proxmox storage для системного диска LXC.
- Выбор отдельного физического диска для файлов Nextcloud.
- Форматирование отдельного data-диска в ext4 и автоматическое монтирование.
- Защита обнаруженных системных дисков Proxmox от выбора в качестве data-диска.
- Проверка APT-репозиториев.
- Если Enterprise-репозиторий Proxmox возвращает `401 Unauthorized`, установщик может сделать резервную копию конфигурации, отключить Enterprise/Ceph Enterprise и подключить официальный `pve-no-subscription` для Proxmox VE 9 / Debian 13.
- DHCP или статический IPv4.
- Автоматически генерируемые пароли.

## Быстрый запуск

Запускайте команду **в Shell самого узла Proxmox**, не внутри VM или LXC:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Viend1211/Nextcloud-installer/main/install.sh)"
```

В веб-интерфейсе Proxmox:

```text
Datacenter
└── pve
    └── Shell
```

Вставьте команду выше и нажмите Enter.

## Quick Install

В Quick-режиме используются значения по умолчанию:

| Параметр | Значение |
|---|---|
| Тип | unprivileged LXC |
| ОС | Debian 13/12 template |
| CPU | 2 cores |
| RAM | 4096 MB |
| Swap | 1024 MB |
| System disk | 20 GB |
| Database | PostgreSQL |
| Cache / locking | Redis |
| Web server | Nginx |
| Network | выбирается пользователем |
| Data filesystem | ext4 |

Пользователь выбирает:

1. Proxmox storage для системного диска контейнера.
2. Отдельный физический диск для пользовательских файлов или хранение внутри LXC.
3. DHCP или статический IP.
4. Подтверждение установки.

## Advanced Install

Дополнительно можно выбрать:

- CT ID;
- hostname;
- CPU;
- RAM;
- swap;
- размер rootfs;
- имя администратора Nextcloud;
- максимальный размер загрузки;
- PostgreSQL или MariaDB;
- Proxmox storage;
- отдельный data-диск;
- bridge;
- DHCP или статический IP/gateway.

## Работа с дисками

Установщик пытается определить физические диски, на которых расположен Proxmox, включая диски, используемые VG `pve`, и исключает их из списка доступных data-дисков.

Перед очисткой выбранного data-диска показываются:

- `/dev/...`;
- размер;
- модель;
- serial number.

Для подтверждения необходимо вручную ввести точное имя устройства, например:

```text
/dev/sda
```

После подтверждения выбранный диск **полностью очищается** и создаётся один раздел ext4 с меткой:

```text
NEXTCLOUD_DATA
```

На Proxmox он монтируется в:

```text
/mnt/nextcloud-data
```

В LXC:

```text
/mnt/data
```

Nextcloud использует:

```text
/mnt/data/data
```

## Proxmox repositories

Proxmox VE Enterprise repository требует действующей подписки. Если Enterprise repository включён без подписки, `apt update` может возвращать:

```text
401 Unauthorized
```

Для Proxmox VE 9 официальный no-subscription repository имеет вид:

```text
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

Документация Proxmox:

https://pve.proxmox.com/pve-docs/pve-admin-guide.html

> Proxmox отмечает, что `pve-no-subscription` предназначен прежде всего для тестирования и не проходит тот же уровень проверки, что Enterprise repository.

Перед изменением APT-конфигурации установщик сохраняет резервную копию в:

```text
/root/nextcloud-installer-backups/
```

## После установки

Установщик выводит:

```text
URL
LXC ID
Nextcloud admin/password
LXC root password
Database/password
System storage
Data disk
```

Сохраните эти данные сразу после установки.

Для постоянной эксплуатации рекомендуется:

- закрепить IP контейнера в DHCP или использовать статический IP;
- настроить DNS;
- настроить HTTPS;
- не публиковать HTTP-порт Nextcloud напрямую в интернет;
- настроить резервное копирование Nextcloud, БД и data-диска;
- регулярно обновлять Proxmox и Nextcloud.

## Структура проекта

```text
Nextcloud-installer/
├── install.sh
├── README.md
├── LICENSE
├── lib/
│   ├── common.sh
│   ├── repos.sh
│   ├── storage.sh
│   ├── lxc.sh
│   └── nextcloud.sh
└── templates/
    └── nginx.conf
```

`install.sh` является небольшим bootstrap-файлом. Он загружает актуальные модули из ветки `main`, после чего запускает интерактивный установщик.

## Обновление

Чтобы получить новую версию установщика, достаточно снова выполнить ту же команду:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Viend1211/Nextcloud-installer/main/install.sh)"
```

## Безопасность

Никогда не запускайте скрипт форматирования дисков, если не понимаете, какой диск выбран.

Перед использованием проверьте:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
```

Если на выбранном диске есть важные данные, остановите установку.

Также рекомендуется просмотреть содержимое скрипта перед запуском:

```bash
curl -fsSL https://raw.githubusercontent.com/Viend1211/Nextcloud-installer/main/install.sh
```

## License

MIT
