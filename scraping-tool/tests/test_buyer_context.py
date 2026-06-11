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
    """MTG（2026/6/8）で更新した二段構え予算・築年緩和・値下げ待ちが反映されている。"""
    prompt = cis.build_fallback_system_prompt()
    for marker in ["1.3億", "30万円", "築30年", "流動性", "管理", "値下げ"]:
        assert marker in prompt, f"戦略プロンプトに {marker!r} が含まれていない"
    # 旧方針の文言が残っていないこと（退行防止）
    assert "本命2010〜2018年" not in prompt
    assert "9,300万〜1.03億" not in prompt


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
