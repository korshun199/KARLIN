#!/usr/bin/env bash
# Подготовка отдельного образа Linux без записи на карту или EEPROM.
set -Eeuo pipefail
umask 077

# Фиксированные пути отделяют рабочую копию от оригинала и физической карты.
work='/home/work/tmp/vesta-linux-test-PSFxdt'
source_image="$work/root-luks-working.img"
prepared_image="$work/root-prepared.img"
boot_image="$work/boot-working.fat"
output_image="$work/vesta-linux-test.img"
keyfile='/home/oleg/Documents/rpi-key-backup-W1MyRUWr/luks-keyfile.secret'
public_key='/home/oleg/.ssh/id_ed25519.pub'
expected_root='f2bdb48a71c01381499ff16f4ccdb44aace4539718009ac72a7c16c79c1e9db1'
expected_boot='0d095375376240a6809cb059bdc276217b413a8523e8f78019d1f83830ba30f4'
expected_sig='77f3fb06f00002bbeceb9812ffc69d1aeef065aa105e6d8c7fd77ab0f1efe226'
mapper='vesta_linux_test_prepare'
mountpoint="$work/root-mount"
loop_device=''
opened=0
mounted=0

# Сообщает об ошибке и останавливает работу.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
# Сообщает о ходе работы без раскрытия ключей.
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }
# Отключает только ресурсы, созданные текущим запуском.
cleanup() {
    local failed=0
    if (( mounted )); then umount -- "$mountpoint" || failed=1; fi
    if (( opened )); then cryptsetup close "$mapper" || failed=1; fi
    if [[ -n "$loop_device" ]]; then losetup -d "$loop_device" || failed=1; fi
    if (( failed )); then printf '[ERROR] Cleanup failed; inspect the mapper and mount before retrying.\n' >&2; fi
}
trap cleanup EXIT

(( EUID == 0 )) || fail 'Run this script with sudo.'
for cmd in sha256sum cryptsetup losetup mount umount install awk grep sed ssh-keygen mtype sfdisk dd cmp truncate stat getent; do
    command -v "$cmd" >/dev/null || fail "Missing command: $cmd"
done
[[ -d "$work" && ! -L "$work" ]] || fail 'Working directory is missing or is a symlink.'
for f in "$source_image" "$boot_image" "$keyfile" "$public_key"; do
    [[ -f "$f" && ! -L "$f" ]] || fail "Missing or unsafe input: $f"
done
[[ ! -e "$prepared_image" && ! -e "$output_image" && ! -e "$mountpoint" ]] || fail 'Output already exists; refusing to overwrite.'
[[ ! -e "/dev/mapper/$mapper" ]] || fail 'Mapper name already exists.'
[[ $(stat -c %s "$source_image") == 1391460352 ]] || fail 'Unexpected LUKS image size.'
[[ $(stat -c %s "$boot_image") == 67108864 ]] || fail 'Unexpected boot image size.'
info 'Checking encrypted image and signed boot file hashes.'
[[ $(sha256sum "$source_image" | awk '{print $1}') == "$expected_root" ]] || fail 'LUKS source hash mismatch.'
[[ $(mtype -i "$boot_image" ::boot.img | sha256sum | awk '{print $1}') == "$expected_boot" ]] || fail 'Signed boot image hash mismatch.'
[[ $(mtype -i "$boot_image" ::boot.sig | sha256sum | awk '{print $1}') == "$expected_sig" ]] || fail 'Boot signature file hash mismatch.'
ssh-keygen -lf "$public_key" >/dev/null || fail 'Invalid SSH public key.'
cryptsetup open --test-passphrase --key-file "$keyfile" "$source_image" || fail 'LUKS key was rejected.'

info 'Creating and opening a separate encrypted working copy.'
install -m 600 -- "$source_image" "$prepared_image"
loop_device=$(losetup --find --show "$prepared_image") || fail 'Could not allocate loop device.'
cryptsetup open --key-file "$keyfile" "$loop_device" "$mapper" || fail 'Could not open working copy.'
opened=1
mkdir -m 700 "$mountpoint"
mount -o rw,nodev,nosuid,noexec "/dev/mapper/$mapper" "$mountpoint" || fail 'Could not mount working copy.'
mounted=1

# Проверка ожидаемой структуры предотвращает изменение неожиданной системы.
root="$mountpoint"
for d in "$root/etc" "$root/etc/systemd" "$root/etc/systemd/system" "$root/home" "$root/home/pi" "$root/var" "$root/var/backups"; do
    [[ -d "$d" && ! -L "$d" ]] || fail "Unexpected directory or symlink: $d"
done
profile="$root/etc/NetworkManager/system-connections/Wired connection 1.nmconnection"
app_link="$root/etc/systemd/system/multi-user.target.wants/DeliveryDrone.service"
ssh_link="$root/etc/systemd/system/multi-user.target.wants/ssh.service"
ssh_dir="$root/home/pi/.ssh"
backup="$root/var/backups/vesta-linux-test"
[[ -f "$profile" && ! -L "$profile" ]] || fail 'Expected wired profile not found.'
[[ -L "$app_link" ]] || fail 'Expected application autostart link not found.'
[[ -f "$root/lib/systemd/system/ssh.service" && -f "$root/usr/sbin/sshd" ]] || fail 'SSH server files missing.'
[[ -d "$ssh_dir" && ! -L "$ssh_dir" && ! -e "$ssh_dir/authorized_keys" ]] || fail 'SSH directory is unexpected or already has authorized keys.'
[[ ! -e "$ssh_link" && ! -e "$backup" ]] || fail 'SSH link or backup already exists.'
[[ $(awk -F: '$1=="pi" {print $3 ":" $4}' "$root/etc/passwd") == '1000:1000' ]] || fail 'Unexpected pi UID/GID.'
[[ $(grep -c '^autoconnect=false$' "$profile") == 1 ]] || fail 'Unexpected autoconnect setting.'

info 'Disabling the old application and enabling wired networking and SSH.'
mkdir -m 700 "$backup"
cp -p -- "$profile" "$backup/wired-profile.original"
mv -- "$app_link" "$backup/DeliveryDrone.service.autostart-link"
sed -i 's/^autoconnect=false$/autoconnect=true/' "$profile"
chmod 600 "$profile"
chown root:root "$profile"
install -o 1000 -g 1000 -m 600 -- "$public_key" "$ssh_dir/authorized_keys"
chown 1000:1000 "$ssh_dir"
chmod 700 "$ssh_dir"
ln -s /lib/systemd/system/ssh.service "$ssh_link"
[[ ! -e "$app_link" && -L "$ssh_link" ]] || fail 'Autostart verification failed.'
grep -qx 'autoconnect=true' "$profile" || fail 'Network verification failed.'
cmp -s "$public_key" "$ssh_dir/authorized_keys" || fail 'SSH public key verification failed.'
if awk -F: '$1=="pi" && $2 ~ /^[!*]/ {found=1} END {exit !found}' "$root/etc/shadow"; then
    printf '\033[33m[WARN] Account pi is locked; SSH login might fail. No password was changed.\033[0m\n'
fi
sync
umount -- "$mountpoint" || fail 'Could not unmount prepared filesystem.'
mounted=0
cryptsetup close "$mapper" || fail 'Could not close prepared mapper.'
opened=0
losetup -d "$loop_device" || fail 'Could not detach loop.'
loop_device=''

# Новый файл образа создаётся без перезаписи; идентификатор раздела сохранён.
info 'Assembling a separate image; no physical disk is accessed.'
( set -C; : > "$output_image" ) || fail 'Output image already exists.'
truncate -s 2147483648 "$output_image"
printf 'label: dos\nlabel-id: 0x66f92843\nunit: sectors\n\nstart=2048, size=131072, type=c, bootable\nstart=133120, size=2717696, type=83\n' | sfdisk --no-reread "$output_image" >/dev/null
dd if="$boot_image" of="$output_image" bs=4M seek=1048576 oflag=seek_bytes conv=notrunc status=none
dd if="$prepared_image" of="$output_image" bs=4M seek=68157440 oflag=seek_bytes conv=notrunc status=progress
sync
info 'Comparing both partitions byte for byte.'
cmp -n 67108864 -i 1048576:0 "$output_image" "$boot_image" || fail 'Boot partition mismatch.'
cmp -n 1391460352 -i 68157440:0 "$output_image" "$prepared_image" || fail 'Root partition mismatch.'
chown 1000:1000 "$output_image" "$prepared_image"
chmod 600 "$output_image" "$prepared_image"
printf '\033[32m[OK] Prepared image: %s\033[0m\n' "$output_image"
sha256sum "$output_image"
printf '[INFO] The SD card and EEPROM were not modified. Hardware boot is not yet verified.\n'
