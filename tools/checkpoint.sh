#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Использование: ./tools/checkpoint.sh \"Описание сохранения\"" >&2
    exit 1
fi

message="$*"

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Команда запущена не внутри Git-репозитория." >&2
    exit 1
fi

if [[ -z "$(git status --porcelain)" ]]; then
    echo "Новых изменений нет; GitHub уже содержит последнюю контрольную точку."
    exit 0
fi

git add -A
git commit -m "$message"
git push
echo "Контрольная точка отправлена в GitHub."
