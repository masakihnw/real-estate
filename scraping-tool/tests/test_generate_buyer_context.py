"""買い手コンテキスト生成器の同期検証テスト。"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


def _load_generator():
    script_path = Path(__file__).resolve().parents[1] / "scripts" / "generate_buyer_context.py"
    spec = importlib.util.spec_from_file_location("generate_buyer_context", script_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    # dataclass デコレータが sys.modules[cls.__module__] を参照するため登録が必須
    sys.modules[spec.name] = module
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
    for spec in gen.PROMPT_SPECS:
        assert gen.generate_ai_prompts_sql(spec) == gen.generate_ai_prompts_sql(spec)
    assert gen.generate_buyer_profiles_sql() == gen.generate_buyer_profiles_sql()


def test_ai_prompts_sql_is_idempotent_and_transactional():
    """idempotent パターン（UPDATE非活性化→UPDATE再活性化→INSERT WHERE NOT EXISTS）かつ
    BEGIN/COMMIT トランザクション内にある。"""
    gen = _load_generator()
    for spec in gen.PROMPT_SPECS:
        sql = gen.generate_ai_prompts_sql(spec)
        assert sql.strip().startswith("--")
        assert "BEGIN;" in sql and sql.rstrip().endswith("COMMIT;")
        # Step 1: 非アクティブ化
        assert "UPDATE ai_prompts SET is_active = false" in sql
        # Step 3: idempotent INSERT（同一コンテンツが既存なら挿入しない）
        assert "WHERE NOT EXISTS" in sql
        # 動的 version 採番（ハードコードなし）
        assert "COALESCE(MAX(version), 0) + 1" in sql
        # INSERT は WHERE NOT EXISTS より後（Step 3 パターン）
        insert_idx = sql.index("INSERT INTO ai_prompts")
        not_exists_idx = sql.index("WHERE NOT EXISTS")
        assert not_exists_idx > insert_idx, "WHERE NOT EXISTS は INSERT の後でなければならない"
        # idempotent パス（Step 2）でも config/notes を上書きする（単独変更のサイレント無視防止）
        step2 = sql[sql.index("Step 2") : insert_idx]
        assert "config =" in step2 and "notes =" in step2


def test_ai_prompts_configs_preserve_production():
    """本番 config（max_items_per_run / rescore_min_score）が退行しないことを検証する。"""
    gen = _load_generator()
    specs = {s.module: s for s in gen.PROMPT_SPECS}
    # version フィールドは動的採番のため PromptSpec には存在しない
    assert not hasattr(specs["investment_summary"], "version")

    sql_summary = gen.generate_ai_prompts_sql(specs["investment_summary"])
    assert '"max_items_per_run": 50' in sql_summary
    assert '"rescore_min_score": 4' in sql_summary

    sql_scoring = gen.generate_ai_prompts_sql(specs["ai_scoring"])
    assert '"max_items_per_run": 100' in sql_scoring
    assert '"rescore_min_score": 65' in sql_scoring
    assert "バイヤープロファイル" in sql_scoring  # ai_scoring 既存テンプレートを踏襲


def test_generated_system_prompt_matches_runtime_fallback():
    """SQL に入る system_prompt がランタイムのフォールバック合成と完全一致する（乖離防止）。"""
    import claude_investment_summarizer as cis

    gen = _load_generator()
    assert gen.compose_system_prompt("investment_summary") == cis.build_fallback_system_prompt()


def _fake_real_profile() -> dict:
    """de-PII マーカー（○ / YYYY / （金額））を一切含まないダミーの実プロフィール。

    実値ではなく合成のテスト用データ（PII を含まない）。
    """
    return {
        "family_composition": "夫（1990年生まれ）・妻（1991年生まれ）、子ども1人",
        "household_income": "1,000万円",
        "self_funds": "なし（フルローン）",
        "interest_type": "変動",
        "estimated_rate": "1.0%",
        "repayment_years": "35年",
        "budget_scenarios": [
            {"label": "探索上限", "value": "1.0億円", "note": "テスト"},
            {"label": "実質アンカー", "value": "9,000万円", "note": "テスト"},
        ],
    }


def test_buyer_profiles_sql_refuses_on_depii_placeholder():
    """退行防止（過去事故 2026-06-13）: de-PII 雛形からは実 buyer_profiles を
    上書きする upsert を生成せず、適用拒否 SQL を出す（フェイルクローズ）。"""
    gen = _load_generator()
    # リポジトリの buyer_profile.json は de-PII 済み（○ / YYYY を含む）。
    assert gen._contains_depii_placeholder(gen.load_buyer_profile())
    sql = gen.generate_buyer_profiles_sql()
    assert "SELECT upsert_buyer_profile(" not in sql, "雛形から適用可能な upsert を生成してはならない"
    assert "RAISE EXCEPTION" in sql
    assert "de-PII" in sql
    # 診断用に検出マーカーがSQLコメントに残る（現行ファイルは ○ を含む）。
    assert "検出マーカー:" in sql and "○" in sql


def test_buyer_profiles_sql_emits_upsert_for_real_profile(monkeypatch):
    """実値（マーカーなし）プロフィールの時のみ通常の upsert を生成する。"""
    gen = _load_generator()
    monkeypatch.setattr(gen, "load_buyer_profile", _fake_real_profile)
    sql = gen.generate_buyer_profiles_sql()
    assert "SELECT upsert_buyer_profile(" in sql
    assert gen.BUYER_USER_ID in sql
    assert "BEGIN;" in sql and "COMMIT;" in sql
    assert "1,000万円" in sql  # 実値が反映される
    assert "RAISE EXCEPTION" not in sql


def test_contains_depii_placeholder_detector():
    gen = _load_generator()
    assert gen._contains_depii_placeholder({"household_income": "○○○○万円"})
    assert gen._contains_depii_placeholder({"family_composition": "夫（YYYY年生まれ）"})
    assert gen._contains_depii_placeholder({"note": "旧試算例（金額）円"})
    assert not gen._contains_depii_placeholder(_fake_real_profile())
