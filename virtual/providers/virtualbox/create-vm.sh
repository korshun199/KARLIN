#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
vm_name="KARLIN VM 0"
iso="$repo_dir/build/virtual/virtualbox/karlin-vm-0.iso"

if [[ ! -f "$iso" ]]; then
    "$repo_dir/virtual/providers/virtualbox/build-iso.sh"
fi

if VBoxManage showvminfo "$vm_name" >/dev/null 2>&1; then
    echo "Виртуальная машина уже существует: $vm_name"
else
    VBoxManage createvm --name "$vm_name" --ostype Linux_64 --register
    VBoxManage modifyvm "$vm_name" --memory 256 --cpus 1 --vram 16 \
        --boot1 dvd --audio-driver none --nic1 nat
    VBoxManage storagectl "$vm_name" --name IDE --add ide
    VBoxManage storageattach "$vm_name" --storagectl IDE --port 0 --device 0 \
        --type dvddrive --medium "$iso"
fi

echo "Создано: $vm_name"
echo "Запуск: VBoxManage startvm \"$vm_name\" --type gui"
