#!/usr/bin/env bash
# Показывает только разрешённые сетевые параметры сохранённого профиля Vesta.
set -Eeuo pipefail

# Профиль является копией, не настройкой работающего компьютера.
profile='/home/copy_vps/Vesta/01_система/rootfs/etc/NetworkManager/system-connections/Wired connection 1.nmconnection'
if (( EUID != 0 )); then
    printf '[ERROR] Run with sudo to read the protected copy.\n' >&2
    exit 1
fi
if [[ ! -f "$profile" || -L "$profile" || ! -r "$profile" ]]; then
    printf '[ERROR] Saved profile is missing, unreadable, or a symlink.\n' >&2
    exit 1
fi
printf '[INFO] Reading only selected network fields from the saved profile.\n'
awk '
    /^\[/ { section=$0; next }
    /^[[:space:]]*#/ || !/=/ { next }
    {
        equal=index($0,"="); key=substr($0,1,equal-1)
        if ((section=="[connection]" && key ~ /^(id|type|interface-name|autoconnect)$/) ||
            ((section=="[ipv4]" || section=="[ipv6]") && key ~ /^(method|addresses|address[0-9]+|gateway|dns|dns-search|never-default|route-metric)$/))
            print section " " $0
    }
' "$profile" || { printf '[ERROR] Could not read profile.\n' >&2; exit 1; }
printf '[INFO] Read-only inspection complete; no settings changed.\n'
