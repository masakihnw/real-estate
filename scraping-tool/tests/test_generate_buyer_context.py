"""買い手コンテキスト生成器の同期検証テスト。"""

from __future__ import annotations

import importlib.util
from pathlib import Path


def _load_generator():
    script_path = Path(__file__).resolve().parents[1] / "scripts" / "generate_buyer_context.py"
    spec = importlib.util.spec_from_file_location("generate_buyer_context", script_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_buyer_profile_doc_is_up_to_date():
    gen = _load_generator()
    expected = gen.generate_buyer_profile_md()
    actual = gen.DOC_PATH.read_text(encoding="utf-8")
    assert actual == expected, "docs/BUYER_PROFILE.md が古い。--write で再生成してください。"


def test_sql_generation_is_deterministic():
    """out/ は gitignore（PII含むSupabase適用用生成物）。コミット比較ではなく決定論を検証する。"""
    gen = _load_generator()
    assert gen.generate_ai_prompts_sql() == gen.generate_ai_prompts_sql()
    assert gen.generate_buyer_profiles_sql() == gen.generate_buyer_profiles_sql()


def test_ai_prompts_sql_is_transactional_and_ordered():
    """INSERT(v2,is_active=true) → UPDATE(旧無効化) の順でトランザクション内にある。"""
    gen = _load_generator()
    sql = gen.generate_ai_prompts_sql()
    assert sql.strip().startswith("--")
    assert "BEGIN;" in sql and sql.rstrip().endswith("COMMIT;")
    insert_idx = sql.index("INSERT INTO ai_prompts")
    update_idx = sql.index("UPDATE ai_prompts SET is_active = false")
    assert insert_idx < update_idx, "INSERT は UPDATE より前でなければならない"
    assert '"max_items_per_run":80' in sql


def test_buyer_profiles_sql_uses_upsert_rpc():
    gen = _load_generator()
    sql = gen.generate_buyer_profiles_sql()
    assert "upsert_buyer_profile" in sql
    assert gen.BUYER_USER_ID in sql
    assert "BEGIN;" in sql and "COMMIT;" in sql
