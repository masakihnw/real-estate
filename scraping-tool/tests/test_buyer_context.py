"""買い手コンテキスト（戦略プロンプト＋買い手プロフィール）の単一ソース検証。"""

from __future__ import annotations

import hashlib
import importlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import claude_investment_summarizer as cis  # noqa: E402

_CONFIG_DIR = Path(__file__).resolve().parents[1] / "config"
_BUYER_PROFILE_PATH = _CONFIG_DIR / "buyer_profile.json"


# ─────────────────────── 戦略プロンプト（正準ソース） ───────────────────────
def test_fallback_prompt_reflects_mtg_policy():
    """MTG（2026/6/8）の築年緩和・値下げ待ち・管理重視が戦略プロンプトに反映されている。

    予算の具体数値（1.3億/30万）はプロンプトに持たせず buyer_profile の予算シナリオで
    1元管理する（本番v4のデータ駆動設計を踏襲）。数値の検証は test_budget_scenarios_* で行う。
    """
    prompt = cis.build_fallback_system_prompt()
    for marker in ["築30年", "流動性", "管理", "値下げ", "二段構え"]:
        assert marker in prompt, f"戦略プロンプトに {marker!r} が含まれていない"
    # 旧方針の文言が残っていないこと（退行防止）
    assert "築年: 2006年以降、本命2010〜2018年" not in prompt


def test_fallback_prompt_preserves_v4_logic():
    """本番v4由来の面積ルール・スコア緩和を退行させていないこと（戦略参照に一般化済み）。"""
    prompt = cis.build_fallback_system_prompt()
    assert "面積が戦略の本命ライン未満の場合のシナリオ分析ルール" in prompt
    assert "面積不足だけを理由にスコア1にしない" in prompt
    assert "65㎡以上が本命" in prompt  # 本命ラインの実値は戦略側が持つ


def test_fallback_prompt_composes_strategy_and_task():
    """フォールバックは「購入戦略コンテキスト → タスク定義」の順で合成される。"""
    prompt = cis.build_fallback_system_prompt()
    assert prompt.startswith("## 購入戦略コンテキスト")
    strategy_idx = prompt.index("## 予算判断（二段構え）")
    task_idx = prompt.index("## シナリオ適合分析（必須）")
    assert strategy_idx < task_idx, "戦略がタスク定義より前に来ること"
    # JSON 出力指示がプロンプト末尾側にあること（タスク定義が後段）
    assert "JSON形式で回答" in prompt[task_idx:]


def test_prompt_version_is_deterministic():
    """同入力で PROMPT_VERSION が固定（キャッシュキー安定）。"""
    prompt = cis.build_fallback_system_prompt()
    expected = hashlib.sha256(prompt.encode()).hexdigest()[:12]
    assert cis.PROMPT_VERSION == expected
    assert cis.PROMPT_VERSION == cis._FALLBACK_PROMPT_VERSION


def test_prompt_version_importable_for_prepopulate_cache():
    """prepopulate_cache.py が import する PROMPT_VERSION が存在する。"""
    mod = importlib.import_module("claude_investment_summarizer")
    assert hasattr(mod, "PROMPT_VERSION")
    assert isinstance(mod.PROMPT_VERSION, str) and len(mod.PROMPT_VERSION) == 12


def test_build_fallback_never_raises_when_md_missing(monkeypatch):
    """.md 不在でも例外を投げず安全網を返す（import を絶対に落とさない）。"""
    monkeypatch.setattr(cis, "_STRATEGY_PROMPT_PATH", Path("/nonexistent/strategy.md"))
    prompt = cis.build_fallback_system_prompt()
    assert prompt == cis._EMBEDDED_SAFETY_PROMPT
    assert prompt  # 空でない


def test_build_fallback_never_raises_when_task_md_missing(monkeypatch):
    """戦略は存在するがタスク定義 .md だけ欠損した場合も安全網を返す。"""
    monkeypatch.setattr(cis, "_TASK_PROMPT_PATH", Path("/nonexistent/task.md"))
    prompt = cis.build_fallback_system_prompt()
    assert prompt == cis._EMBEDDED_SAFETY_PROMPT


# ─────────────────────── 買い手プロフィール（budget_scenarios） ───────────────────────
def _load_profile() -> dict:
    return json.loads(_BUYER_PROFILE_PATH.read_text(encoding="utf-8"))


def test_buyer_profile_has_budget_scenarios():
    profile = _load_profile()
    scenarios = profile.get("budget_scenarios")
    assert isinstance(scenarios, list) and len(scenarios) >= 1
    labels = {s.get("label") for s in scenarios}
    assert "探索上限" in labels
    assert "実質アンカー" in labels


def test_budget_scenarios_carry_mtg_figures():
    """MTGの二段構え数値（1.3億・1.1億・30万）は buyer_profile に1元化されている。"""
    blob = json.dumps(_load_profile().get("budget_scenarios", []), ensure_ascii=False)
    assert "1.3億" in blob
    assert "1.1億" in blob
    assert "30万" in blob


def test_budget_scenarios_values_are_all_strings():
    """iOS の [String: String] キャストが無音失敗しないよう全値が文字列であること。"""
    profile = _load_profile()
    for scenario in profile.get("budget_scenarios", []):
        assert isinstance(scenario, dict)
        for key, value in scenario.items():
            assert isinstance(key, str)
            assert isinstance(value, str), f"budget_scenarios の {key!r} が文字列でない: {value!r}"


def test_format_buyer_profile_renders_budget_scenarios():
    profile = _load_profile()
    rendered = cis._format_buyer_profile(profile)
    assert "予算シナリオ:" in rendered
    assert "探索上限" in rendered
    assert "1.3億" in rendered


def test_no_stale_calculation_example():
    """旧試算例（26.94万円）が残っていないこと（退行防止）。"""
    raw = _BUYER_PROFILE_PATH.read_text(encoding="utf-8")
    assert "26.94" not in raw
