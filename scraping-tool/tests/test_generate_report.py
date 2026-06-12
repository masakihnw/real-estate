"""generate_report.generate_markdown の特性テスト（refactor Phase 1 安全網）。

レポートの中核仕様を固定する:
- 資産性B以上（listing_score >= 50）のみ表示、スコアなしは未分析として含める
- diff の new はB以上のみ「新規物件」セクションに出る
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from generate_report import _is_listing_score_b_or_above, generate_markdown  # noqa: E402


def _listing(**overrides) -> dict:
    base = {
        "name": "パークタワー晴海",
        "layout": "3LDK",
        "area_m2": 70.5,
        "price_man": 9800,
        "address": "東京都中央区晴海2丁目3-1",
        "built_year": 2019,
        "walk_min": 5,
        "station_line": "都営大江戸線「勝どき」徒歩5分",
        "floor_position": 10,
        "floor_total": 48,
        "total_units": 1084,
        "source": "suumo",
        "url": "https://example.com/suumo/1",
        "listing_score": 70,
    }
    base.update(overrides)
    return base


# ─────────────────────── スコアフィルタ ───────────────────────


def test_score_filter_boundary_is_50():
    assert _is_listing_score_b_or_above({"listing_score": 50})
    assert not _is_listing_score_b_or_above({"listing_score": 49})


def test_score_filter_none_is_included():
    """スコア未分析の物件は除外しない（現仕様）。"""
    assert _is_listing_score_b_or_above({"listing_score": None})
    assert _is_listing_score_b_or_above({})


def test_low_score_listing_excluded_from_report():
    high = _listing(listing_score=70)
    low = _listing(
        name="低スコアマンション", listing_score=30, url="https://example.com/suumo/2"
    )
    md = generate_markdown([high, low])
    assert "対象件数**: 1件（資産性B以上 / 全2件中）" in md
    assert "低スコアマンション" not in md


def test_unscored_listing_included_in_report():
    md = generate_markdown([_listing(listing_score=None)])
    assert "対象件数**: 1件（資産性B以上 / 全1件中）" in md


# ─────────────────────── 新規物件セクション ───────────────────────


def test_new_section_rendered_for_new_b_or_above():
    new = _listing(name="新着タワーマンション", url="https://example.com/suumo/9")
    md = generate_markdown([new], diff={"new": [new], "updated": [], "removed": []})
    assert "## 🆕 新規物件" in md
    assert "新着タワーマンション" in md


def test_new_section_omits_low_score_new():
    """新規でもB未満は新規物件セクションに出ない。"""
    new_low = _listing(
        name="低スコア新着", listing_score=20, url="https://example.com/suumo/9"
    )
    md = generate_markdown(
        [new_low], diff={"new": [new_low], "updated": [], "removed": []}
    )
    assert "## 🆕 新規物件" not in md


def test_no_new_section_without_diff():
    md = generate_markdown([_listing()])
    assert "## 🆕 新規物件" not in md


# ─────────────────────── ヘッダ・リンク ───────────────────────


def test_report_header_and_optional_links():
    md = generate_markdown(
        [_listing()],
        report_url="https://github.com/example/repo/tree/main/results/report",
        map_url="https://example.com/map.html",
    )
    assert md.startswith("# 中古マンション物件一覧レポート")
    assert "https://github.com/example/repo/tree/main/results/report" in md
    assert "https://example.com/map.html" in md
    assert "## 🔍 検索条件（一覧）" in md


def test_links_omitted_when_blank():
    md = generate_markdown([_listing()], report_url="  ", map_url=None)
    assert "レポート（GitHub）" not in md
    assert "物件マップ" not in md
