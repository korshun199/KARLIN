#!/usr/bin/env bash
# Безопасно отменяет подготовленное обновление, сохраняя его файлы.
set -Eeuo pipefail
umask 077

# Ошибка означает остановку без перезагрузки и без записи EEPROM.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
# Выводит этап работы.
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }

(( EUID == 0 )) || fail 'Run with sudo on the Raspberry Pi.'
# Журнал хранится в tmpfs, потому что корневой раздел заполнен.
if [[ ${VESTA_EEPROM_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /tmp/vesta-eeprom-cancel-XXXXXXXX.log) || fail 'Cannot create log.'
    # В sticky-каталоге /tmp файл должен принадлежать root: иначе ядро может
    # запретить root открыть его на запись при fs.protected_regular=2.
    chown 0:1000 "$log" || fail 'Cannot assign log owner.'
    chmod 640 "$log" || fail 'Cannot secure log.'
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_EEPROM_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    results=("${PIPESTATUS[@]}")
    if (( results[1] != 0 )); then printf '[ERROR] Log write failed.\n' >&2; fi
    if (( results[0] != 0 )); then exit "${results[0]}"; fi
    if (( results[1] != 0 )); then exit 1; fi
    exit 0
fi

# Ограничивает действия проверенной Raspberry и её загрузочным разделом.
[[ $(hostname) == delivery ]] || fail 'Unexpected host.'
grep -q 'Raspberry Pi 4 Model B' /proc/device-tree/model || fail 'Unexpected board model.'
[[ $(findmnt -nro SOURCE -T /boot/firmware) == /dev/mmcblk0p1 ]] || fail 'Unexpected boot filesystem.'
[[ -f /boot/firmware/boot.img && -f /boot/firmware/boot.sig ]] || fail 'Signed boot files missing.'
[[ ! -e /boot/firmware/pieeprom.bin && ! -e /boot/firmware/vl805.bin && ! -e /boot/firmware/vl805.sig ]] || fail 'Unexpected additional update files; manual inspection required.'

# Проверяет именно те три файла, резервная копия которых снята на ноутбук.
cd /boot/firmware
printf '%s\n' \
 'd1c076d6f536b591ca88200eaaf092de93b49917f47414aabb8976d0e5aa38c3  recovery.bin' \
 'ad4476060264c2061f2e47f1ae18695831830677b784d59ce7bd739a78a7cdba  pieeprom.upd' \
 'ebde28e7ccadab9ad19ef9214147ae23d27f1f7e5477284cb28509640a3d0efd  pieeprom.sig' | sha256sum -c - || fail 'Pending files changed; no action taken.'
boot_hash=$(sha256sum boot.img | awk '{print $1}')
sig_hash=$(sha256sum boot.sig | awk '{print $1}')
[[ "$boot_hash" == 0d095375376240a6809cb059bdc276217b413a8523e8f78019d1f83830ba30f4 ]] || fail 'Signed boot image changed.'

# Сохраняет копии на том же FAT-разделе и проверяет их до перемещения оригиналов.
backup=$(mktemp -d /boot/firmware/.vesta-eeprom-backup-XXXXXXXX) || fail 'Cannot create backup directory.'
mkdir "$backup/copies" "$backup/removed"
for name in recovery.bin pieeprom.upd pieeprom.sig; do
    cp -- "$name" "$backup/copies/$name"
    cmp -s -- "$name" "$backup/copies/$name" || fail "Backup mismatch: $name"
done
cp /lib/systemd/system/rpi-eeprom-update.service "$backup/copies/rpi-eeprom-update.service"
sync
info "Verified backup: $backup"

# Отключает только автоподготовку; сама EEPROM и прошивки не меняются.
systemctl disable rpi-eeprom-update.service
if systemctl is-enabled --quiet rpi-eeprom-update.service; then fail 'EEPROM update service is still enabled.'; fi
info 'Automatic EEPROM update preparation disabled.'
for name in recovery.bin pieeprom.upd pieeprom.sig; do
    mv -- "$name" "$backup/removed/$name"
done
sync
for name in recovery.bin pieeprom.upd pieeprom.sig; do
    [[ ! -e "$name" ]] || fail "Pending file still present: $name"
    cmp -s "$backup/copies/$name" "$backup/removed/$name" || fail "Moved file mismatch: $name"
done
[[ $(sha256sum boot.img | awk '{print $1}') == "$boot_hash" && $(sha256sum boot.sig | awk '{print $1}') == "$sig_hash" ]] || fail 'Boot files changed unexpectedly.'
printf '\033[32m[OK] Pending update files moved to backup and automatic preparation disabled.\033[0m\n'
printf '[INFO] EEPROM was not written and the Raspberry was not rebooted.\n'
