#!/usr/bin/env bash
# Устанавливает доступ к текущему экрану только через SSH-туннель.
set -Eeuo pipefail
umask 077

# Выводит ошибку и останавливает сценарий.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
# Сообщает об очередном этапе.
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }

(( EUID == 0 )) || fail 'Run with sudo on the Raspberry Pi.'
# Сохраняет вывод, не записывая вводимый пользователем пароль.
if [[ ${VESTA_X11VNC_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /tmp/vesta-x11vnc-install-XXXXXXXX.log) || fail 'Cannot create log.'
    chown 0:1000 "$log"; chmod 640 "$log"
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_X11VNC_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    result=("${PIPESTATUS[@]}")
    if (( result[1] != 0 )); then printf '[ERROR] Log write failed.\n' >&2; fi
    if (( result[0] != 0 )); then exit "${result[0]}"; fi
    if (( result[1] != 0 )); then exit 1; fi
    exit 0
fi

export LC_ALL=C DEBIAN_FRONTEND=noninteractive
[[ $(hostname) == delivery ]] || fail 'Unexpected host.'
grep -q 'Raspberry Pi 4 Model B' /proc/device-tree/model || fail 'Unexpected board.'
[[ $(findmnt -nro SOURCE -T /) == /dev/mapper/secret ]] || fail 'Unexpected root filesystem.'
systemctl is-active --quiet lightdm || fail 'LightDM is not active.'
[[ -r /run/lightdm/root/:0 ]] || fail 'X authority file is unavailable.'
[[ ! -e /etc/systemd/system/vesta-x11vnc.service && ! -e /etc/vesta-x11vnc.pass ]] || fail 'Existing VNC setup found; refusing to overwrite.'
[[ -z $(ss -H -lnt '( sport = :5900 )') ]] || fail 'TCP port 5900 is already in use.'
[[ ! -e /boot/firmware/recovery.bin && ! -e /boot/firmware/pieeprom.upd ]] || fail 'Pending EEPROM update found.'
if systemctl is-enabled --quiet rpi-eeprom-update.service; then fail 'EEPROM auto-update service is enabled.'; fi

# Проверяет план установки; пакеты загрузчика и обновления запрещены.
plan=$(mktemp /tmp/vesta-x11vnc-plan-XXXXXXXX.txt) || fail 'Cannot create plan.'
info 'Simulating package installation.'
apt-get -s --no-install-recommends --no-upgrade install x11vnc > "$plan" 2>&1 || { cat "$plan"; fail 'APT simulation failed.'; }
cat "$plan"
grep -Eq '^0 upgraded, [0-9]+ newly installed, 0 to remove' "$plan" || fail 'APT plan contains upgrades or removals.'
if grep -Eq '^Inst (rpi-eeprom|raspberrypi-bootloader|raspberrypi-kernel|raspi-firmware|linux-image|initramfs-tools|cryptsetup|systemd)([ :(-]|$)' "$plan"; then
    fail 'APT plan touches protected boot or system packages.'
fi
info 'Installing x11vnc without a full upgrade.'
apt-get -y --no-install-recommends --no-upgrade install x11vnc || fail 'Package installation failed.'
[[ ! -e /boot/firmware/recovery.bin && ! -e /boot/firmware/pieeprom.upd ]] || fail 'An EEPROM update appeared; do not reboot.'

# Пользователь вводит отдельный пароль в терминале; его значение не выводится.
printf '\033[33m[INFO] Choose a separate VNC password (up to 8 characters); do not send it in chat.\033[0m\n'
[[ -t 0 ]] || fail 'Interactive terminal required to set the VNC password.'
/usr/bin/x11vnc -storepasswd /etc/vesta-x11vnc.pass || fail 'VNC password setup failed.'
[[ -s /etc/vesta-x11vnc.pass && ! -L /etc/vesta-x11vnc.pass ]] || fail 'VNC password file was not created.'
chown root:root /etc/vesta-x11vnc.pass
chmod 600 /etc/vesta-x11vnc.pass

# Новый сервис не меняет существующие конфиги и слушает только loopback.
unit=/etc/systemd/system/vesta-x11vnc.service
( set -C; printf '%s\n' '[Unit]' 'Description=Vesta local VNC over SSH' 'Requires=lightdm.service' 'After=lightdm.service' '' '[Service]' 'Type=simple' 'ExecStart=/usr/bin/x11vnc -norc -display :0 -auth /run/lightdm/root/:0 -localhost -no6 -rfbport 5900 -rfbauth /etc/vesta-x11vnc.pass -forever -shared -noxdamage' 'Restart=on-failure' 'RestartSec=3' '' '[Install]' 'WantedBy=multi-user.target' > "$unit" ) || fail 'Cannot create service safely.'
chmod 644 "$unit"
systemctl daemon-reload
systemctl enable --now vesta-x11vnc.service || fail 'Could not start VNC service; inspect journal.'
systemctl is-active --quiet vesta-x11vnc.service || fail 'VNC service is not active.'
# Служба может открыть порт немного позже перехода в состояние active.
listener=''
for attempt in {1..30}; do
    listener=$(ss -H -lnt '( sport = :5900 )') || fail 'Cannot inspect VNC listener.'
    [[ -n "$listener" ]] && break
    sleep 0.2
done
[[ -n "$listener" ]] || fail 'VNC listener did not appear.'
while read -r state recvq sendq local_address peer_address; do
    case "$local_address" in
        127.0.0.1:5900|'[::1]:5900') ;;
        *) fail 'VNC listener is not restricted to localhost.' ;;
    esac
done <<< "$listener"
[[ "$listener" == *'127.0.0.1:5900'* ]] || fail 'IPv4 localhost listener is missing.'
printf '\033[32m[OK] VNC is active on 127.0.0.1:5900 with password protection.\033[0m\n'
printf '[INFO] SSH settings and local login policy were not changed; no reboot or EEPROM update was initiated.\n'
