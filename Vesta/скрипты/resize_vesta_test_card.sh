#!/usr/bin/env bash
# Расширяет только согласованную тестовую карту после резервного копирования.
set -Eeuo pipefail
umask 077

# Фиксированные параметры не позволяют подставить другой носитель или ключ.
disk='/dev/sda'
part='/dev/sda2'
link='/dev/disk/by-id/usb-Generic_Mass-Storage_20240418000000-0:0'
key='/home/oleg/Documents/rpi-key-backup-W1MyRUWr/luks-keyfile.secret'
meta='/home/work/tmp/vesta-resize-metadata-TIfHCJ'
mapper='vesta_resize_offline'
opened=0

# Сообщает ошибку, не выполняя автоматического восстановления.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
# Показывает этап работы.
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }
# Закрывает только mapper, созданный текущим запуском.
cleanup() {
    if (( opened )); then
        cryptsetup close "$mapper" || printf '[ERROR] Could not close mapper; inspect it before removing the card.\n' >&2
    fi
}
trap cleanup EXIT

(( EUID == 0 )) || fail 'Run with sudo on the laptop.'
# Полный вывод и ошибки сохраняются в приватном рабочем каталоге.
if [[ ${VESTA_RESIZE_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /home/work/tmp/vesta-linux-test-PSFxdt/card-resize-XXXXXXXX.log) || fail 'Cannot create log.'
    chown 1000:1000 "$log"; chmod 600 "$log"
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_RESIZE_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    result=("${PIPESTATUS[@]}")
    if (( result[1] != 0 )); then printf '[ERROR] Log write failed.\n' >&2; fi
    if (( result[0] != 0 )); then exit "${result[0]}"; fi
    if (( result[1] != 0 )); then exit 1; fi
    exit 0
fi

for cmd in lsblk findmnt readlink sha256sum sfdisk dd cmp cryptsetup e2fsck resize2fs blockdev partprobe udevadm mtype blkid df awk swapon umount sync; do
    command -v "$cmd" >/dev/null || fail "Missing command: $cmd"
done
[[ -f "$key" && ! -L "$key" ]] || fail 'LUKS key file missing or unsafe.'
[[ -d "$meta" && ! -L "$meta" ]] || fail 'Metadata backup missing.'
( cd "$meta" && sha256sum -c SHA256SUMS ) || fail 'Saved metadata failed verification.'

# Проверяет карту, текущую разметку и отсутствие других дочерних устройств.
[[ -L "$link" && $(readlink -f "$link") == "$disk" && -b "$disk" ]] || fail 'Unexpected target device.'
[[ $(lsblk -dnro TYPE "$disk") == disk && $(lsblk -dnro TRAN "$disk") == usb && $(lsblk -dnro RM "$disk") == 1 && $(lsblk -dnro RO "$disk") == 0 ]] || fail 'Target is not the expected writable removable USB disk.'
[[ $(lsblk -bdnro SIZE "$disk") == 125069950976 ]] || fail 'Unexpected card size.'
[[ $(lsblk -dnro SERIAL "$disk" | tr -d '[:space:]') == 20240418000000 ]] || fail 'Unexpected reader serial.'
[[ $(cat /sys/block/sda/sda1/start) == 2048 && $(cat /sys/block/sda/sda1/size) == 131072 ]] || fail 'Unexpected boot partition geometry.'
[[ $(cat /sys/block/sda/sda2/start) == 133120 && $(cat /sys/block/sda/sda2/size) == 2717696 ]] || fail 'Unexpected root partition geometry.'
[[ $(blkid -s PARTUUID -o value "$part") == 66f92843-02 ]] || fail 'Unexpected root PARTUUID.'
[[ $(sfdisk --disk-id "$disk") == 0x66f92843 ]] || fail 'Unexpected MBR disk ID.'
cmp -n 512 "$meta/mbr.bin" "$disk" || fail 'MBR does not match the saved metadata.'
[[ $(lsblk -dnro LABEL /dev/sda1) == VESTABOOT ]] || fail 'Unexpected boot label.'
[[ ! -e "/dev/mapper/$mapper" ]] || fail 'Mapper name already exists.'
structure=$(lsblk -nrpo PATH,TYPE "$disk") || fail 'Cannot inspect target structure.'
while read -r node kind; do
    case "$kind:$node" in disk:/dev/sda|part:/dev/sda1|part:/dev/sda2) ;; *) fail "Unexpected target child: $node ($kind).";; esac
done <<< "$structure"
root_source=$(findmnt -nro SOURCE /) || fail 'Cannot identify laptop root.'
root_chain=$(lsblk -snrpo PATH "$root_source") || fail 'Cannot identify laptop root disk.'
if grep -Fxq "$disk" <<< "$root_chain"; then fail 'Target contains the laptop root.'; fi

# Проверка swap и свободного места перед любыми изменениями.
swap_list=$(swapon --show=NAME --noheadings --raw) || fail 'Cannot inspect swap.'
while IFS= read -r swap; do
    [[ -n "$swap" ]] || continue
    resolved=$(readlink -f "$swap") || fail 'Cannot resolve swap.'
    [[ "$resolved" != /dev/sda && "$resolved" != /dev/sda1 && "$resolved" != /dev/sda2 ]] || fail 'Target is used as swap.'
    if [[ -f "$resolved" ]]; then
        source=$(findmnt -nro SOURCE -T "$resolved") || fail 'Cannot inspect swap file.'
        [[ "$source" != /dev/sda && "$source" != /dev/sda1 && "$source" != /dev/sda2 ]] || fail 'Swap file is on target.'
    fi
done <<< "$swap_list"
available=$(df -PB1 /home/work | awk 'NR==2 {print $4}')
[[ "$available" =~ ^[0-9]+$ ]] && (( available > 3221225472 )) || fail 'Less than 3 GiB is available for the backup.'
cryptsetup isLuks "$part" || fail 'Root partition is not LUKS.'
[[ $(cryptsetup luksUUID "$part") == "$(cryptsetup luksUUID "$meta/luks-header.bin")" ]] || fail 'LUKS UUID does not match the backup.'
cryptsetup open --test-passphrase --key-file "$key" "$part" || fail 'LUKS key was rejected.'
[[ $(mtype -i /dev/sda1 ::boot.img | sha256sum | awk '{print $1}') == 0d095375376240a6809cb059bdc276217b413a8523e8f78019d1f83830ba30f4 ]] || fail 'Signed boot image does not match.'

# Снимает все смонтированные разделы только проверенного носителя.
if findmnt -rn -S "$disk" >/dev/null; then fail 'Whole target disk is mounted.'; fi
for node in /dev/sda1 /dev/sda2; do
    if findmnt -rn -S "$node" >/dev/null; then umount -- "$node" || fail "Cannot unmount $node."; fi
    if findmnt -rn -S "$node" >/dev/null; then fail "$node remains mounted."; fi
done
[[ $(readlink -f "$link") == "$disk" && $(lsblk -bdnro SIZE "$disk") == 125069950976 ]] || fail 'Target changed after unmount.'

# Сохраняет все занятые первые 2 ГиБ, включая таблицу, boot и LUKS.
backup=$(mktemp -d /home/work/tmp/vesta-before-resize-XXXXXXXX) || fail 'Cannot create backup directory.'
chown 1000:1000 "$backup"; chmod 700 "$backup"
info "Creating a 2 GiB pre-resize snapshot: $backup/card-first-2g.img"
dd if="$disk" of="$backup/card-first-2g.img" bs=4M count=512 iflag=fullblock status=progress
[[ $(stat -c %s "$backup/card-first-2g.img") == 2147483648 ]] || fail 'Incomplete pre-resize snapshot.'
cmp -n 2147483648 "$disk" "$backup/card-first-2g.img" || fail 'Snapshot does not match card.'
sfdisk --dump "$disk" > "$backup/partition-table.sfdisk"
sha256sum "$backup/card-first-2g.img" "$backup/partition-table.sfdisk" > "$backup/SHA256SUMS"
chown 1000:1000 "$backup/card-first-2g.img" "$backup/partition-table.sfdisk" "$backup/SHA256SUMS"
chmod 600 "$backup/card-first-2g.img" "$backup/partition-table.sfdisk" "$backup/SHA256SUMS"
info "Verified snapshot saved: $backup"

# Проверяет ext4 до изменения разметки и не исправляет ошибки автоматически.
cryptsetup open --key-file "$key" "$part" "$mapper" || fail 'Cannot open LUKS.'
opened=1
info 'Checking the existing filesystem without repairs.'
e2fsck -f -n "/dev/mapper/$mapper" || fail 'Filesystem check reported errors; partition not resized.'
cryptsetup close "$mapper" || fail 'Cannot close mapper before resize.'
opened=0

# Изменяет только конец второго раздела, сохраняя MBR ID и начало раздела.
info 'Expanding partition 2; preserving its start and PARTUUID.'
printf 'start=133120, size=+\n' | sfdisk --no-reread -N 2 "$disk" || fail 'Partition update failed; do not remove the card.'
partprobe "$disk" || fail 'Kernel could not reread partition table; do not continue.'
udevadm settle
[[ $(cat /sys/block/sda/sda1/start) == 2048 && $(cat /sys/block/sda/sda1/size) == 131072 ]] || fail 'Boot partition geometry changed.'
[[ $(cat /sys/block/sda/sda2/start) == 133120 ]] || fail 'Root partition start changed.'
[[ $(sfdisk --disk-id "$disk") == 0x66f92843 && $(lsblk -dnro PARTUUID "$part") == 66f92843-02 ]] || fail 'MBR disk ID or PARTUUID changed.'
new_size=$(blockdev --getsize64 "$part")
(( new_size > 100000000000 )) || fail 'Kernel still reports the old partition size.'

# Заново открывает LUKS по новому размеру и расширяет размонтированный ext4.
cryptsetup open --key-file "$key" "$part" "$mapper" || fail 'Cannot open LUKS after resize.'
opened=1
(( $(blockdev --getsize64 "/dev/mapper/$mapper") > 100000000000 )) || fail 'LUKS mapper is still small.'
info 'Expanding the unmounted ext4 filesystem.'
resize2fs "/dev/mapper/$mapper" || fail 'Filesystem resize failed; retain the backup.'
info 'Checking the resized filesystem without repairs.'
e2fsck -f -n "/dev/mapper/$mapper" || fail 'Post-resize check reported errors.'
cryptsetup close "$mapper" || fail 'Cannot close mapper after resize.'
opened=0
sync
[[ $(mtype -i /dev/sda1 ::boot.img | sha256sum | awk '{print $1}') == 0d095375376240a6809cb059bdc276217b413a8523e8f78019d1f83830ba30f4 ]] || fail 'Signed boot image changed.'
printf '\033[32m[OK] Test card partition and LUKS/ext4 filesystem expanded and checked.\033[0m\n'
printf '[INFO] Pre-resize snapshot: %s\n' "$backup"
printf '[INFO] EEPROM and original card were not modified; boot has not yet been tested.\n'
