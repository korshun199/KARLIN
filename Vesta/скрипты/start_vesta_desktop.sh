#!/usr/bin/env bash
# Запускает уже установленный экран входа и локальную VNC-службу Raspberry.
set -Eeuo pipefail
umask 077

# Сообщает об ошибке и останавливает скрипт.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || fail 'Run with sudo on the Raspberry Pi.'
if [[ ${VESTA_START_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /tmp/vesta-desktop-start-XXXXXXXX.log) || fail 'Cannot create log.'
    chown root:pi "$log"; chmod 640 "$log"
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_START_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    result=("${PIPESTATUS[@]}")
    (( result[0] == 0 )) || exit "${result[0]}"
    (( result[1] == 0 )) || fail 'Log write failed.'
    exit 0
fi
grep -q 'Raspberry Pi 4 Model B' /proc/device-tree/model || fail 'Unexpected board.'
[[ $(findmnt -nro SOURCE -T /) == /dev/mapper/secret ]] || fail 'Unexpected root filesystem.'
printf '[INFO] Starting the existing LightDM service.\n'
systemctl start lightdm || fail 'LightDM start failed.'
for attempt in {1..30}; do
    [[ -r /run/lightdm/root/:0 ]] && break
    sleep 1
done
[[ -r /run/lightdm/root/:0 ]] || fail 'X display authorization did not appear.'
printf '[INFO] Starting the existing local VNC service.\n'
systemctl start vesta-x11vnc || fail 'VNC start failed.'
systemctl is-active --quiet lightdm && systemctl is-active --quiet vesta-x11vnc || fail 'A service is not active.'
printf '\033[32m[OK] Desktop and VNC services are active.\033[0m\n'
