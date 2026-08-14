#!/usr/bin/env bash
set -euo pipefail

echo "Проверка хоста KARLIN VM 0"

if ! command -v VBoxManage >/dev/null 2>&1; then
    echo "ОШИБКА: VBoxManage не найден. Установите VirtualBox." >&2
    exit 1
fi
echo "OK: $(VBoxManage --version | head -1)"

if [[ ! -e /dev/vboxdrv ]]; then
    echo "ОШИБКА: /dev/vboxdrv отсутствует. Модуль VirtualBox не загружен." >&2
    echo "На обычном хосте попробуйте: sudo /sbin/vboxconfig" >&2
    exit 1
fi
echo "OK: модуль VirtualBox доступен"

kernel="${KARLIN_KERNEL:-/boot/vmlinuz-$(uname -r)}"
if [[ ! -r "$kernel" ]]; then
    echo "ОШИБКА: ядро недоступно для чтения: $kernel" >&2
    echo "Передайте путь: KARLIN_KERNEL=/путь/к/vmlinuz" >&2
    exit 1
fi
echo "OK: ядро доступно: $kernel"

echo "Хост готов к сборке и запуску KARLIN VM 0"
