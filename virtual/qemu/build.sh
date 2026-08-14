#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
build_dir="$repo_dir/build/virtual/qemu"
rootfs_dir="$build_dir/rootfs"
kernel="${KARLIN_KERNEL:-/boot/vmlinuz-$(uname -r)}"

if [[ ! -r "$kernel" ]]; then
    echo "Не найдено читаемое Linux-ядро: $kernel" >&2
    echo "Укажите путь через KARLIN_KERNEL=/путь/к/ядру" >&2
    exit 1
fi

rm -rf "$build_dir"
mkdir -p "$rootfs_dir/bin" "$rootfs_dir/dev" "$rootfs_dir/proc" \
    "$rootfs_dir/sys" "$rootfs_dir/tmp"

cp /bin/busybox "$rootfs_dir/bin/busybox"
chmod 755 "$rootfs_dir/bin/busybox"
ln -s busybox "$rootfs_dir/bin/sh"
ln -s busybox "$rootfs_dir/bin/clear"
ln -s busybox "$rootfs_dir/bin/ls"
ln -s busybox "$rootfs_dir/bin/uname"

cp "$repo_dir/virtual/qemu/init" "$rootfs_dir/init"
chmod 755 "$rootfs_dir/init"

(cd "$rootfs_dir" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9) \
    > "$build_dir/initramfs.cpio.gz"
cp "$kernel" "$build_dir/kernel"

echo "Собрано: $build_dir/initramfs.cpio.gz"
echo "Ядро:    $kernel"
