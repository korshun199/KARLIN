#!/usr/bin/env python3
"""Обновляет локальный список текстовых чат-моделей из публичного каталога AITunnel."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen


# Каталог не требует API-ключ и содержит только модели группы chat.
CATALOG_URL = "https://api.aitunnel.ru/public/aitunnel/models/chat"
# Страница каталога для человека и указания происхождения снимка.
CATALOG_PAGE = "https://aitunnel.ru/models?modality=chat"


def load_catalog(url: str) -> dict:
    """Загружает JSON-карту моделей и проверяет корневой формат ответа."""
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "MashaUsbWindowsModelCatalog/1.0"})
    with urlopen(request, timeout=30) as response:
        data = json.load(response)
    if not isinstance(data, dict):
        raise ValueError("Корень ответа каталога должен быть JSON-объектом.")
    return data


def compatible_ids(catalog: dict) -> list[str]:
    """Оставляет записи с текстовым входом и текстовым выходом."""
    ids = []
    for model_id, details in catalog.items():
        if not isinstance(model_id, str) or not model_id or not isinstance(details, dict):
            continue
        modalities = details.get("modalities")
        if not isinstance(modalities, dict):
            continue
        inputs = modalities.get("input", [])
        outputs = modalities.get("output", [])
        if isinstance(inputs, list) and isinstance(outputs, list) and "text" in inputs and "text" in outputs:
            ids.append(model_id)
    return sorted(set(ids))


def save_catalog(output: Path, ids: list[str]) -> None:
    """Сохраняет список и метаданные источника атомарной заменой файла."""
    output.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "source_api": CATALOG_URL,
        "source_page": CATALOG_PAGE,
        "fetched_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "compatibility_rule": {
            "group": "chat",
            "input_must_include": "text",
            "output_must_include": "text",
        },
        "models": ids,
    }
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output)


def main() -> int:
    """Обновляет файл рядом с приложением и печатает итог без вывода секретов."""
    project_root = Path(__file__).resolve().parents[1]
    default_output = project_root / "src" / "Masha.App" / "chat_models.json"
    parser = argparse.ArgumentParser(description="Обновить совместимый список моделей чата AITunnel.")
    parser.add_argument("--output", type=Path, default=default_output, help="Путь выходного JSON-файла")
    arguments = parser.parse_args()
    try:
        catalog = load_catalog(CATALOG_URL)
        ids = compatible_ids(catalog)
        if not ids:
            raise ValueError("После фильтрации каталог не содержит текстовых чат-моделей.")
        save_catalog(arguments.output, ids)
    except (OSError, URLError, TimeoutError, ValueError, json.JSONDecodeError) as error:
        print(f"[ОШИБКА] Каталог не обновлён: {error}", file=sys.stderr)
        return 1
    print(f"[OK] Совместимых чат-моделей: {len(ids)}")
    print(f"[OK] Файл: {arguments.output.resolve()}")
    print("[INFO] Учитывается текстовый ввод и текстовый вывод; возможность вызова инструментов каталог отдельно не подтверждает.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
