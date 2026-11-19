#!/usr/bin/env bash
# Создаёт копию таблицы разделов и заголовка LUKS без изменения карты.
set -Eeuo pipefail
umask 077

# Сообщает об ошибке и прерывает работу.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
# Сообщает этап работы.
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }

(( EUID == 0 )) || fail 'Run with sudo on the Raspberry Pi.'
# Журнал хранится в tmpfs: корневой раздел заполнен.
if [[ ${VESTA_BACKUP_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /tmp/vesta-resize-metadata-XXXXXXXX.log) || fail 'Cannot create log.'
    chown 0:1000 "$log" || fail 'Cannot assign log group.'
    chmod 640 "$log" || fail 'Cannot secure log.'
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_BACKUP_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    results=("${PIPESTATUS[@]}")
    if (( results[1] != 0 )); then printf '[ERROR] Log write failed.\n' >&2; fi
    if (( results[0] != 0 )); then exit "${results[0]}"; fi
    if (( results[1] != 0 )); then exit 1; fi
    exit 0
fi

# Проверяет устройство, геометрию и статус отложенного обновления.
for cmd in cryptsetup sfdisk dd sha256sum findmnt lsblk blkid; do
    command -v "$cmd" >/dev/null || fail "Missing command: $cmd"
done
[[ $(hostname) == delivery ]] || fail 'Unexpected host.'
grep -q 'Raspberry Pi 4 Model B' /proc/device-tree/model || fail 'Unexpected board.'
[[ $(findmnt -nro SOURCE -T /) == /dev/mapper/secret ]] || fail 'Unexpected root filesystem.'
[[ $(lsblk -bdnro SIZE /dev/mmcblk0) == 125069950976 ]] || fail 'Unexpected card size.'
[[ $(cat /sys/block/mmcblk0/mmcblk0p2/start) == 133120 ]] || fail 'Unexpected root partition start.'
[[ $(cat /sys/block/mmcblk0/mmcblk0p2/size) == 2717696 ]] || fail 'Unexpected root partition size.'
[[ $(blkid -s PARTUUID -o value /dev/mmcblk0p2) == 66f92843-02 ]] || fail 'Unexpected partition identifier.'
[[ ! -e /boot/firmware/recovery.bin && ! -e /boot/firmware/pieeprom.upd ]] || fail 'Pending EEPROM update found.'
if systemctl is-enabled --quiet rpi-eeprom-update.service; then fail 'EEPROM auto-update service is enabled.'; fi
cryptsetup isLuks /dev/mmcblk0p2 || fail 'Root partition is not LUKS.'

# Защищает резервные метаданные от доступа других пользователей.
backup=$(mktemp -d /tmp/vesta-resize-backup-XXXXXXXX) || fail 'Cannot create backup directory.'
chown 1000:1000 "$backup"
chmod 700 "$backup"
info "Backup directory: $backup"
sfdisk --dump /dev/mmcblk0 > "$backup/partition-table.sfdisk"
dd if=/dev/mmcblk0 of="$backup/mbr.bin" bs=512 count=1 status=none
cryptsetup luksHeaderBackup /dev/mmcblk0p2 --header-backup-file "$backup/luks-header.bin"
[[ $(stat -c %s "$backup/mbr.bin") == 512 ]] || fail 'MBR backup size is invalid.'
cryptsetup isLuks "$backup/luks-header.bin" || fail 'Header backup is not recognized as LUKS.'
chown 1000:1000 "$backup/partition-table.sfdisk" "$backup/mbr.bin" "$backup/luks-header.bin"
chmod 600 "$backup/partition-table.sfdisk" "$backup/mbr.bin" "$backup/luks-header.bin"
cd "$backup"
sha256sum partition-table.sfdisk mbr.bin luks-header.bin > SHA256SUMS
chown 1000:1000 SHA256SUMS
chmod 600 SHA256SUMS
sha256sum -c SHA256SUMS || fail 'Backup verification failed.'
printf '\033[32m[OK] Metadata backup completed: %s\033[0m\n' "$backup"
printf '[INFO] No partition, filesystem, EEPROM, or boot file was changed.\n'
printf '[WARNING] Backup is in RAM and will disappear on reboot; copy it to the laptop first.\n'
