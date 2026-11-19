#!/usr/bin/env bash
# Устанавливает просмотрщик с масштабированием на ноутбуке и сохраняет журнал.
set -Eeuo pipefail
umask 077

# Сообщает об ошибке и завершает установку.
fail() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || fail 'Run with sudo on the laptop.'
if [[ ${VESTA_SCALED_LOG_ACTIVE:-} != 1 ]]; then
    log=$(mktemp /home/work/tmp/vesta-linux-test-PSFxdt/scaled-viewer-install-XXXXXXXX.log) || fail 'Cannot create log.'
    chown 1000:1000 "$log"; chmod 600 "$log"
    printf '[INFO] Log: %s\n' "$log" | tee -a "$log" || fail 'Cannot write log.'
    set +e
    VESTA_SCALED_LOG_ACTIVE=1 bash "$0" "$@" 2>&1 | tee -a "$log"
    result=("${PIPESTATUS[@]}")
    (( result[0] == 0 )) || exit "${result[0]}"
    (( result[1] == 0 )) || fail 'Log write failed.'
    exit 0
fi
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
[[ $(dpkg --print-architecture) == amd64 ]] || fail 'Unexpected laptop architecture.'
[[ -z $(dpkg --audit) ]] || fail 'Package database needs repair.'
plan=$(mktemp /tmp/vesta-scaled-viewer-plan-XXXXXXXX.txt) || fail 'Cannot create plan.'
printf '[INFO] Simulating scaled viewer installation.\n'
apt-get -s --no-install-recommends --no-upgrade install ssvnc > "$plan" 2>&1 || { cat "$plan"; fail 'APT simulation failed.'; }
cat "$plan"
grep -Eq '^0 upgraded, [0-9]+ newly installed, 0 to remove' "$plan" || fail 'APT plan includes upgrades or removals.'
apt-get -y --no-install-recommends --no-upgrade install ssvnc || fail 'Viewer installation failed.'
command -v ssvncviewer >/dev/null || fail 'Scaled viewer not found.'
printf '\033[32m[OK] Scaled viewer installed.\033[0m\n'
