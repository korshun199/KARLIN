#!/usr/bin/env bash
# Устанавливает просмотрщик TigerVNC на ноутбук без обновления системы.
set -Eeuo pipefail
umask 077

# Выводит ошибку и прекращает работу.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || fail 'Run with sudo on the laptop.'
# Сохраняет вывод в личном каталоге проекта.
if [[ ${VESTA_VIEWER_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /home/work/tmp/vesta-linux-test-PSFxdt/viewer-install-XXXXXXXX.log) || fail 'Cannot create log.'
    chown 1000:1000 "$log"; chmod 600 "$log"
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_VIEWER_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    result=("${PIPESTATUS[@]}")
    if (( result[1] != 0 )); then printf '[ERROR] Log write failed.\n' >&2; fi
    if (( result[0] != 0 )); then exit "${result[0]}"; fi
    if (( result[1] != 0 )); then exit 1; fi
    exit 0
fi

export LC_ALL=C DEBIAN_FRONTEND=noninteractive
[[ $(dpkg --print-architecture) == amd64 ]] || fail 'Unexpected laptop architecture.'
[[ -z $(dpkg --audit) ]] || fail 'Package database needs repair.'
plan=$(mktemp /tmp/vesta-viewer-plan-XXXXXXXX.txt) || fail 'Cannot create plan.'
printf '[INFO] Simulating TigerVNC installation.\n'
apt-get -s --no-install-recommends --no-upgrade install tigervnc-viewer > "$plan" 2>&1 || { cat "$plan"; fail 'APT simulation failed.'; }
cat "$plan"
grep -Eq '^0 upgraded, [0-9]+ newly installed, 0 to remove' "$plan" || fail 'APT plan includes upgrades or removals.'
printf '[INFO] Installing TigerVNC without a full system upgrade.\n'
apt-get -y --no-install-recommends --no-upgrade install tigervnc-viewer || fail 'Viewer installation failed.'
command -v vncviewer >/dev/null || fail 'vncviewer was not found after installation.'
printf '\033[32m[OK] TigerVNC viewer installed.\033[0m\n'
