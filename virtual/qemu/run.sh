#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
build_dir="$repo_dir/build/virtual/qemu"

if [[ ! -f "$build_dir/kernel" || ! -f "$build_dir/initramfs.cpio.gz" ]]; then
    "$repo_dir/virtual/qemu/build.sh"
fi

exec qemu-system-x86_64 \
    -machine accel=kvm:tcg \
    -m 256M \
    -smp 1 \
    -kernel "$build_dir/kernel" \
    -initrd "$build_dir/initramfs.cpio.gz" \
    -append 'console=ttyS0 rdinit=/init' \
    -nographic \
    -no-reboot
