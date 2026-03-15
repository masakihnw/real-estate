"""SPECIFICATION の自動生成ブロック整合テスト。"""

from __future__ import annotations

import importlib.util
from pathlib import Path


def _load_doc_generator():
    script_path = Path(__file__).resolve().parents[1] / "scripts" / "generate_scraping_conditions_doc.py"
    spec = importlib.util.spec_from_file_location("generate_scraping_conditions_doc", script_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_spec_scraping_conditions_block_is_up_to_date():
    generator = _load_doc_generator()
    spec_path = Path(__file__).resolve().parents[2] / "docs" / "SPECIFICATION.md"
    content = spec_path.read_text(encoding="utf-8")

    start = content.index(generator.START_MARKER)
    end = content.index(generator.END_MARKER) + len(generator.END_MARKER)
    block = content[start:end]
    expected = generator.generate_conditions_table()
    assert block == expected
