#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
vm_name="KARLIN VM 0"

"$repo_dir/virtual/providers/virtualbox/check-host.sh"

if ! VBoxManage showvminfo "$vm_name" >/dev/null 2>&1; then
    "$repo_dir/virtual/providers/virtualbox/create-vm.sh"
fi

exec VBoxManage startvm "$vm_name" --type gui
