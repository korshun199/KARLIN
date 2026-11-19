#!/usr/bin/env bash
# Запись подготовленного образа только на согласованную тестовую карту.
set -Eeuo pipefail

# Жёстко заданные значения защищают от выбора другого образа и носителя.
image='/home/work/tmp/vesta-linux-test-PSFxdt/vesta-linux-test.img'
image_hash='2714770d6489c04238cf25ad0a49fed1bcd1ead974ed013d596ff4b968fc5dc0'
device_link='/dev/disk/by-id/usb-Generic_Mass-Storage_20240418000000-0:0'
target='/dev/sda'
size='125069950976'
serial='20240418000000'

# Выводит ошибку и прекращает работу.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
# Выводит этап работы.
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }
# Повторно проверяет точный путь, тип и характеристики согласованной карты.
check_target() {
    [[ -L "$device_link" && $(readlink -f "$device_link") == "$target" && -b "$target" ]] || fail 'Target path changed.'
    [[ $(lsblk -dnro TYPE "$target") == disk && $(lsblk -dnro TRAN "$target") == usb ]] || fail 'Target is not a USB disk.'
    [[ $(lsblk -dnro RM "$target") == 1 && $(lsblk -dnro RO "$target") == 0 ]] || fail 'Target is not removable or is read-only.'
    [[ $(lsblk -bdnro SIZE "$target") == "$size" ]] || fail 'Target capacity changed.'
    [[ $(lsblk -dnro SERIAL "$target" | tr -d '[:space:]') == "$serial" ]] || fail 'Reader serial changed.'
    [[ $(lsblk -dnro MODEL "$target" | xargs) == 'Mass-Storage' ]] || fail 'Reader model changed.'
}

(( EUID == 0 )) || fail 'Run this script with sudo.'
# Запускает работу через tee, сохраняя исходный код ошибки скрипта.
if [[ ${VESTA_WRITE_LOG_ACTIVE:-} != 1 ]]; then
    command -v tee >/dev/null || fail 'Missing command: tee'
    command -v mktemp >/dev/null || fail 'Missing command: mktemp'
    [[ -d /home/work/tmp/vesta-linux-test-PSFxdt && ! -L /home/work/tmp/vesta-linux-test-PSFxdt ]] || fail 'Log directory is missing or unsafe.'
    log=$(mktemp /home/work/tmp/vesta-linux-test-PSFxdt/card-write-XXXXXXXX.log) || fail 'Cannot create log.'
    chown 1000:1000 "$log" || fail 'Cannot assign log owner.'
    chmod 600 "$log" || fail 'Cannot secure log.'
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_WRITE_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    results=("${PIPESTATUS[@]}")
    if (( results[1] != 0 )); then printf '[ERROR] Failed to write log: %s\n' "$log" >&2; fi
    if (( results[0] != 0 )); then exit "${results[0]}"; fi
    if (( results[1] != 0 )); then exit 1; fi
    exit 0
fi
for cmd in lsblk readlink sha256sum awk xargs findmnt swapon umount dd cmp sync; do
    command -v "$cmd" >/dev/null || fail "Missing command: $cmd"
done
[[ -f "$image" && ! -L "$image" && $(stat -c %s "$image") == 2147483648 ]] || fail 'Image is missing or has unexpected size.'
info 'Checking image SHA-256.'
[[ $(sha256sum "$image" | awk '{print $1}') == "$image_hash" ]] || fail 'Image hash mismatch.'
check_target

# Защищает системный диск и отказывается от неожиданной структуры носителя.
root_source=$(findmnt -nro SOURCE /) || fail 'Cannot identify root filesystem.'
root_chain=$(lsblk -snrpo PATH "$root_source") || fail 'Cannot identify root disk.'
if grep -Fxq "$target" <<< "$root_chain"; then fail 'Target contains the root filesystem.'; fi
structure=$(lsblk -nrpo PATH,TYPE "$target") || fail 'Cannot inspect target structure.'
while read -r node kind; do
    case "$kind:$node" in disk:/dev/sda|part:/dev/sda1|part:/dev/sda2) ;; *) fail "Unexpected child device: $node ($kind).";; esac
done <<< "$structure"
[[ $(lsblk -dnro LABEL /dev/sda1) == bootfs && $(lsblk -dnro LABEL /dev/sda2) == rootfs ]] || fail 'Partitions are not the expected Raspberry Pi OS test card.'
if findmnt -rn -S "$target" >/dev/null; then fail 'Whole target disk is mounted.'; fi

# Не допускает активный swap-раздел или swap-файл на целевой карте.
swap_list=$(swapon --show=NAME --noheadings --raw) || fail 'Cannot inspect swap.'
while IFS= read -r swap_path; do
    [[ -n "$swap_path" ]] || continue
    resolved=$(readlink -f "$swap_path") || fail 'Cannot resolve swap.'
    [[ "$resolved" != /dev/sda && "$resolved" != /dev/sda1 && "$resolved" != /dev/sda2 ]] || fail 'Swap is active on target.'
    if [[ -f "$resolved" ]]; then
        swap_source=$(findmnt -nro SOURCE -T "$resolved") || fail 'Cannot identify swap file filesystem.'
        [[ "$swap_source" != /dev/sda && "$swap_source" != /dev/sda1 && "$swap_source" != /dev/sda2 ]] || fail 'Swap file is active on target.'
    fi
done <<< "$swap_list"

printf '\033[33m[WARNING] Writing 2 GiB to %s (%s bytes). Existing partitions will be replaced. The remaining tail is not erased.\033[0m\n' "$target" "$size"
info 'Unmounting the two test-card partitions if mounted.'
for part in /dev/sda1 /dev/sda2; do
    if findmnt -rn -S "$part" >/dev/null; then umount -- "$part" || fail "Cannot unmount $part."; fi
    if findmnt -rn -S "$part" >/dev/null; then fail "$part is still mounted."; fi
done
check_target
info 'Writing the prepared image to the confirmed test card.'
dd if="$image" of="$target" bs=4M conv=fsync status=progress
sync
info 'Comparing the written 2 GiB byte for byte.'
cmp -n 2147483648 "$image" "$target" || fail 'Read-back comparison failed.'
printf '\033[32m[OK] Test card write and byte-for-byte verification completed.\033[0m\n'
printf '[INFO] EEPROM and the original card were not touched. Hardware boot remains unverified.\n'
