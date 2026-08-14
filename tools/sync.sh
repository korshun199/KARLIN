#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$repo_dir"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Рабочий каталог содержит незакоммиченные изменения." >&2
    echo "Сначала сохраните их коммитом или разберите вручную." >&2
    git status --short
    exit 1
fi

branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
    echo "Не удалось определить текущую ветку." >&2
    exit 1
fi

git fetch origin
git pull --rebase origin "$branch"
echo "Репозиторий синхронизирован: $branch"
