#!/usr/bin/env bash
# Открывает экран Raspberry через локальный SSH-туннель и закрывает его после выхода.
set -Eeuo pipefail
umask 077

# Выводит ошибку и прекращает выполнение.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
# Выводит этап работы.
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }

(( EUID != 0 )) || fail 'Run this launcher as the laptop user, without sudo.'
# Вывод сохраняется отдельно для каждого запуска.
if [[ ${VESTA_VIEW_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /home/work/tmp/vesta-linux-test-PSFxdt/desktop-open-XXXXXXXX.log) || fail 'Cannot create log.'
    chmod 600 "$log"
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_VIEW_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    result=("${PIPESTATUS[@]}")
    if (( result[1] != 0 )); then printf '[ERROR] Log write failed.\n' >&2; fi
    if (( result[0] != 0 )); then exit "${result[0]}"; fi
    if (( result[1] != 0 )); then exit 1; fi
    exit 0
fi

command -v vncviewer >/dev/null || fail 'TigerVNC viewer is not installed.'
command -v ssh >/dev/null || fail 'SSH client is not installed.'
[[ -n ${DISPLAY:-} ]] || fail 'A graphical laptop session is required.'
[[ -z $(ss -H -lnt '( sport = :15900 )') ]] || fail 'Local port 15900 is already in use.'

# Запускает только собственный туннель и завершает его после закрытия окна.
tunnel_pid=''
cleanup() {
    if [[ -n "$tunnel_pid" ]] && kill -0 "$tunnel_pid" 2>/dev/null; then
        kill "$tunnel_pid" 2>/dev/null || true
        wait "$tunnel_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT
ssh_options=(-i /home/oleg/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=vesta-raspberry -o UserKnownHostsFile=/home/oleg/.ssh/vesta_known_hosts -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes)
ssh "${ssh_options[@]}" pi@delivery.local 'systemctl is-active --quiet vesta-x11vnc.service' || fail 'VNC service is not active on the Raspberry Pi.'
info 'Opening a loopback-only SSH tunnel.'
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -N -L 127.0.0.1:15900:127.0.0.1:5900 pi@delivery.local &
tunnel_pid=$!
ready=0
for attempt in {1..15}; do
    kill -0 "$tunnel_pid" 2>/dev/null || fail 'SSH tunnel exited.'
    if ss -H -lnt '( sport = :15900 )' | grep -q '127.0.0.1:15900'; then ready=1; break; fi
    sleep 1
done
(( ready == 1 )) || fail 'SSH tunnel did not start.'
if command -v ssvncviewer >/dev/null; then
    # Масштабируется только изображение на ноутбуке, разрешение Raspberry не меняется.
    info 'Opening the scaled viewer; enter the VNC password when requested.'
    ssvncviewer -scale 1.7 -nograbkbd 127.0.0.1::15900
else
    info 'Opening TigerVNC; enter the VNC password in the viewer window.'
    vncviewer -Maximize 127.0.0.1::15900
fi
printf '[OK] Viewer closed; the SSH tunnel will close now.\n'
