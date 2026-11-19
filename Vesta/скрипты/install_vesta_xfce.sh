#!/usr/bin/env bash
# Устанавливает XFCE для действующей Raspberry без обновления загрузчика.
set -Eeuo pipefail
umask 077

# Останавливает выполнение с сообщением об ошибке.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
# Показывает этап работы.
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }

(( EUID == 0 )) || fail 'Run with sudo on the Raspberry Pi.'
# Журнал доступен пользователю pi и не раскрывает закрытые ключи.
if [[ ${VESTA_XFCE_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /tmp/vesta-xfce-install-XXXXXXXX.log) || fail 'Cannot create log.'
    chown 0:1000 "$log"; chmod 640 "$log"
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_XFCE_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    result=("${PIPESTATUS[@]}")
    if (( result[1] != 0 )); then printf '[ERROR] Log write failed.\n' >&2; fi
    if (( result[0] != 0 )); then exit "${result[0]}"; fi
    if (( result[1] != 0 )); then exit 1; fi
    exit 0
fi

export LC_ALL=C DEBIAN_FRONTEND=noninteractive
for command in apt-get dpkg systemctl findmnt sha256sum awk grep df; do
    command -v "$command" >/dev/null || fail "Missing command: $command"
done
[[ $(hostname) == delivery ]] || fail 'Unexpected host.'
grep -q 'Raspberry Pi 4 Model B' /proc/device-tree/model || fail 'Unexpected board.'
[[ $(findmnt -nro SOURCE -T /) == /dev/mapper/secret ]] || fail 'Unexpected root filesystem.'
[[ $(findmnt -nro SOURCE -T /boot/firmware) == /dev/mmcblk0p1 ]] || fail 'Unexpected boot filesystem.'
[[ ! -e /boot/firmware/recovery.bin && ! -e /boot/firmware/pieeprom.upd ]] || fail 'Pending EEPROM update found.'
if systemctl is-enabled --quiet rpi-eeprom-update.service; then fail 'EEPROM auto-update service is enabled.'; fi
available=$(df -PB1 / | awk 'NR==2 {print $4}')
[[ "$available" =~ ^[0-9]+$ ]] && (( available > 3221225472 )) || fail 'Less than 3 GiB free on root.'
[[ -z $(dpkg --audit) ]] || fail 'Package database needs repair; inspect before installing.'
boot_hash=$(sha256sum /boot/firmware/boot.img | awk '{print $1}')
sig_hash=$(sha256sum /boot/firmware/boot.sig | awk '{print $1}')
[[ "$boot_hash" == 0d095375376240a6809cb059bdc276217b413a8523e8f78019d1f83830ba30f4 ]] || fail 'Signed boot image changed.'
[[ "$sig_hash" == 77f3fb06f00002bbeceb9812ffc69d1aeef065aa105e6d8c7fd77ab0f1efe226 ]] || fail 'Boot signature file changed.'

# Сохраняет прежний целевой режим systemd до его изменения.
backup=$(mktemp -d /var/backups/vesta-xfce-XXXXXXXX) || fail 'Cannot create backup directory.'
systemctl get-default > "$backup/default-target.txt"
if [[ -L /etc/systemd/system/default.target ]]; then
    cp -a /etc/systemd/system/default.target "$backup/default.target"
fi
info "Saved previous systemd target: $backup"

# Проверяет план APT после обновления индексов, не обновляя систему целиком.
info 'Refreshing package indexes.'
apt-get update || fail 'Package index update failed.'
plan=$(mktemp /tmp/vesta-xfce-plan-XXXXXXXX.txt) || fail 'Cannot create plan.'
info 'Simulating installation before making package changes.'
apt-get -s --no-install-recommends --no-upgrade install xorg xfce4 lightdm lightdm-gtk-greeter > "$plan" 2>&1 || { cat "$plan"; fail 'APT simulation failed.'; }
cat "$plan"
grep -Eq '^0 upgraded, [0-9]+ newly installed, 0 to remove' "$plan" || fail 'APT plan includes upgrades or removals.'
if grep -Eq '^Inst (rpi-eeprom|raspberrypi-bootloader|raspberrypi-kernel|raspi-firmware|linux-image|initramfs-tools|cryptsetup|systemd)([ :(-]|$)' "$plan"; then
    fail 'APT plan touches protected boot or system packages.'
fi

info 'Installing XFCE, Xorg and LightDM without a full upgrade.'
apt-get -y --no-install-recommends --no-upgrade install xorg xfce4 lightdm lightdm-gtk-greeter || fail 'Package installation failed; do not reboot before inspection.'
[[ ! -e /boot/firmware/recovery.bin && ! -e /boot/firmware/pieeprom.upd ]] || fail 'An EEPROM update appeared; do not reboot.'
[[ $(sha256sum /boot/firmware/boot.img | awk '{print $1}') == "$boot_hash" && $(sha256sum /boot/firmware/boot.sig | awk '{print $1}') == "$sig_hash" ]] || fail 'Signed boot files changed; do not reboot.'
systemctl set-default graphical.target || fail 'Could not set graphical boot target.'
info 'Starting LightDM; no automatic login is configured.'
systemctl start lightdm || fail 'LightDM failed to start; inspect the journal.'
systemctl is-active --quiet lightdm || fail 'LightDM is not active.'
printf '\033[32m[OK] XFCE installed, graphical boot target set, and LightDM active.\033[0m\n'
printf '[INFO] Output is expected on the current AV connector; display and login still require physical verification.\n'
printf '[INFO] No reboot or EEPROM update was initiated. Previous target: %s\n' "$backup"
