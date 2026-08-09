# Nextcloud Installer & Manager for Proxmox VE

## v0.3.0

Теперь это не только установщик Nextcloud, но и мастер дальнейшего развития сервера.

Главное меню:

```text
Nextcloud for Proxmox
├── Install a new Nextcloud
├── Manage existing installation
│   ├── Storage & disks
│   │   ├── overview
│   │   ├── upgrade advisor
│   │   ├── add independent Nextcloud disk
│   │   ├── replace current data disk with a larger disk, without RAID
│   │   ├── migrate current data to two new disks RAID1
│   │   ├── add a disk as Proxmox Directory Storage
│   │   ├── expand LXC rootfs
│   │   └── diagnostics
│   ├── Nextcloud administration
│   ├── LXC administration
│   └── diagnostics
└── Exit
```

## Новый Upgrade Advisor

Мастер анализирует текущую конфигурацию и предлагает возможные пути модернизации:

- один свободный диск → добавить как отдельное хранилище или заменить старый большим;
- два свободных диска → предложить RAID1 / ZFS Mirror;
- мало места в LXC → расширить `rootfs`;
- обнаружен текущий `/mnt/nextcloud-data` → предложить безопасную миграцию;
- ZFS уже используется → напомнить о scrub, SMART и snapshots;
- независимо от RAID → напомнить о внешнем backup.

## Замена текущего диска на больший без RAID

Сценарий:

```text
старый HDD
   │
   ├── online rsync
   │
   ▼
новый большой HDD
   │
   ├── maintenance mode
   ├── final rsync
   └── switch bind mount
```

Старый диск автоматически не стирается.

## Переход на RAID1

```text
старый HDD
   │
   ▼
new HDD 1 ─┐
           ├── ZFS Mirror / mdadm RAID1
new HDD 2 ─┘
   │
   ▼
Nextcloud bind mount
```

## Добавление диска без миграции

Можно создать новый ext4-диск, смонтировать его на Proxmox и передать в LXC как `/mnt/dataN`. Затем использовать его в Nextcloud через External Storage.

## Добавление диска для самого Proxmox

Мастер может подготовить отдельный ext4-диск и зарегистрировать его как Directory Storage для:

```text
VM images
LXC rootdir
backups
ISO
templates
```

## Запуск

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Viend1211/Nextcloud-installer/main/install.sh)"
```

## Безопасность

Перед форматированием мастер показывает устройство, размер, модель и serial. Системные диски Proxmox исключаются из выбора насколько это возможно. Тем не менее перед подтверждением всегда сверяйте MODEL и SERIAL.

RAID не является резервной копией.
