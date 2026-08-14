#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
build_dir="$repo_dir/build/virtual/virtualbox"
rootfs_dir="$repo_dir/build/virtual/rootfs"
iso_tree="$build_dir/iso-tree"
kernel="${KARLIN_KERNEL:-/boot/vmlinuz-$(uname -r)}"

for required_command in grub-mkrescue xorriso mformat cpio gzip; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Не найдена команда: $required_command" >&2
        echo "Установите пакет mtools, xorriso или cpio и повторите сборку." >&2
        exit 1
    fi
done

if [[ ! -r "$kernel" ]]; then
    echo "Не найдено читаемое Linux-ядро: $kernel" >&2
    echo "Укажите путь через KARLIN_KERNEL=/путь/к/ядру" >&2
    exit 1
fi

rm -rf "$build_dir" "$rootfs_dir"
mkdir -p "$rootfs_dir/bin" "$rootfs_dir/dev" "$rootfs_dir/proc" \
    "$rootfs_dir/sys" "$rootfs_dir/tmp" "$iso_tree/boot/grub"

cp /bin/busybox "$rootfs_dir/bin/busybox"
chmod 755 "$rootfs_dir/bin/busybox"
for command_name in sh clear ls uname poweroff; do
    ln -s busybox "$rootfs_dir/bin/$command_name"
done

cp "$repo_dir/virtual/guest/init" "$rootfs_dir/init"
chmod 755 "$rootfs_dir/init"

(cd "$rootfs_dir" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9) \
    > "$iso_tree/boot/initramfs.cpio.gz"
cp "$kernel" "$iso_tree/boot/vmlinuz"

cat > "$iso_tree/boot/grub/grub.cfg" <<'GRUB'
set timeout=0
set default=0

menuentry 'KARLIN VM 0' {
    linux /boot/vmlinuz console=tty0 rdinit=/init
    initrd /boot/initramfs.cpio.gz
}
GRUB

grub-mkrescue -o "$build_dir/karlin-vm-0.iso" "$iso_tree" >/dev/null
echo "ISO собрано: $build_dir/karlin-vm-0.iso"
