#!/usr/bin/env bash
set -euo pipefail

# Папка проекта и путь к SDK определяются без изменения системных настроек.
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dotnet_bin="${DOTNET_BIN:-}"
if [[ -z "$dotnet_bin" ]]; then
    dotnet_bin="$(command -v dotnet || true)"
fi
if [[ -z "$dotnet_bin" && -x /home/work/.masha-dotnet/dotnet ]]; then
    dotnet_bin="/home/work/.masha-dotnet/dotnet"
fi
if [[ -z "$dotnet_bin" || ! -x "$dotnet_bin" ]]; then
    printf '\033[31m[ERROR]\033[0m .NET SDK не найден. Укажите его путь в DOTNET_BIN.\n' >&2
    exit 1
fi

# Собираем автономный тестовый EXE для 64-битной Windows.
printf '\033[36m[INFO]\033[0m Сборка первого окна для Windows x64...\n'
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$dotnet_bin" publish \
    "$project_dir/src/Masha.Prototype/Masha.Prototype.csproj" \
    -c Release -r win-x64 --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -o "$project_dir/publish/prototype-win-x64"
printf '\033[32m[OK]\033[0m Прототип: %s\n' "$project_dir/publish/prototype-win-x64/Masha.exe"
printf '\033[33m[INFO]\033[0m Это только окно: ИИ, голос и вложения ещё не работают.\n'
