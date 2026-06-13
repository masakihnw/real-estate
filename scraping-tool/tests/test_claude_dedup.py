"""claude_dedup の純ロジック特性テスト（refactor P8）。

Claude API を叩く judge_dedup_pairs は対象外。候補抽出のブロック化条件
（find_dedup_candidates）と confidence 閾値による適用ロジック
（apply_dedup_results: >=0.9 マージ / 0.6-0.9 フラグ / <0.6 無視）を固定する。
プロンプト本文・モデル呼び出しは変更しない。
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from claude_dedup import (  # noqa: E402
    DedupResult,
    apply_dedup_results,
    find_dedup_candidates,
)


def _listing(**overrides) -> dict:
    base = {
        "name": "パークタワー晴海",
        "address": "東京都中央区晴海2丁目3-1",
        "layout": "3LDK",
        "area_m2": 70.0,
        "price_man": 9800,
        "source": "suumo",
        "url": "https://example.com/s/1",
    }
    base.update(overrides)
    return base


# ─────────────────────── find_dedup_candidates ───────────────────────


def test_candidates_cross_source_similar_area_price():
    a = _listing(source="suumo", url="https://example.com/s/1")
    b = _listing(source="homes", url="https://example.com/h/1")
    cands = find_dedup_candidates([a, b])
    assert len(cands) == 1
    assert {cands[0].idx_a, cands[0].idx_b} == {0, 1}


def test_candidates_same_source_excluded():
    a = _listing(source="suumo", url="https://example.com/s/1")
    b = _listing(source="suumo", url="https://example.com/s/2")
    assert find_dedup_candidates([a, b]) == []


def test_candidates_area_gap_over_3_excluded():
    a = _listing(source="suumo", area_m2=70.0)
    b = _listing(source="homes", area_m2=74.0, url="https://example.com/h/1")
    assert find_dedup_candidates([a, b]) == []


def test_candidates_area_gap_within_3_included():
    a = _listing(source="suumo", area_m2=70.0)
    b = _listing(source="homes", area_m2=72.5, url="https://example.com/h/1")
    assert len(find_dedup_candidates([a, b])) == 1


def test_candidates_price_diff_over_15pct_excluded():
    a = _listing(source="suumo", price_man=9800)
    b = _listing(source="homes", price_man=12000, url="https://example.com/h/1")
    assert find_dedup_candidates([a, b]) == []


def test_candidates_zero_price_skips_price_filter():
    a = _listing(source="suumo", price_man=0)
    b = _listing(source="homes", price_man=9800, url="https://example.com/h/1")
    # 価格0は比較スキップ → 面積・建物一致で候補になる
    assert len(find_dedup_candidates([a, b])) == 1


def test_candidates_different_building_excluded():
    a = _listing(name="パークタワー晴海", source="suumo")
    b = _listing(name="ブリリア有明", address="東京都江東区有明1丁目",
                 source="homes", url="https://example.com/h/1")
    assert find_dedup_candidates([a, b]) == []


# ─────────────────────── apply_dedup_results ───────────────────────


def test_apply_high_confidence_merges_and_drops_secondary():
    a = _listing(source="suumo", url="https://example.com/s/1")
    b = _listing(source="homes", url="https://example.com/h/1", price_man=9700)
    out = apply_dedup_results(
        [a, b],
        [DedupResult(idx_a=0, idx_b=1, same_unit=True, confidence=0.95, reasoning="同一")],
    )
    assert len(out) == 1
    assert out[0]["url"] == "https://example.com/s/1"
    assert out[0]["dedup_confidence"] == 0.95
    assert len(out[0]["alt_sources"]) == 1
    assert out[0]["alt_sources"][0]["source"] == "homes"


def test_apply_mid_confidence_flags_without_merge():
    a = _listing(source="suumo", url="https://example.com/s/1")
    b = _listing(source="homes", url="https://example.com/h/1")
    out = apply_dedup_results(
        [a, b],
        [DedupResult(idx_a=0, idx_b=1, same_unit=True, confidence=0.7, reasoning="たぶん")],
    )
    # 両方残る。primary に候補フラグが付く
    assert len(out) == 2
    assert out[0]["dedup_candidates"][0]["confidence"] == 0.7


def test_apply_low_confidence_ignored():
    a = _listing(source="suumo", url="https://example.com/s/1")
    b = _listing(source="homes", url="https://example.com/h/1")
    out = apply_dedup_results(
        [a, b],
        [DedupResult(idx_a=0, idx_b=1, same_unit=True, confidence=0.5, reasoning="別")],
    )
    assert len(out) == 2
    assert "dedup_candidates" not in out[0]


def test_apply_not_same_unit_ignored_even_high_confidence():
    a = _listing(source="suumo", url="https://example.com/s/1")
    b = _listing(source="homes", url="https://example.com/h/1")
    out = apply_dedup_results(
        [a, b],
        [DedupResult(idx_a=0, idx_b=1, same_unit=False, confidence=0.99, reasoning="別物件")],
    )
    assert len(out) == 2


def test_apply_already_merged_index_skipped():
    """同一 index が複数ペアに登場しても二重マージしない（confidence 降順で先勝ち）。"""
    a = _listing(source="suumo", url="https://example.com/s/1")
    b = _listing(source="homes", url="https://example.com/h/1")
    c = _listing(source="rehouse", url="https://example.com/r/1")
    out = apply_dedup_results(
        [a, b, c],
        [
            DedupResult(idx_a=0, idx_b=1, same_unit=True, confidence=0.95, reasoning="A=B"),
            DedupResult(idx_a=1, idx_b=2, same_unit=True, confidence=0.92, reasoning="B=C"),
        ],
    )
    # idx1 が先にマージ済みなので 2番目のペアはスキップ。残るのは a と c
    assert len(out) == 2
    urls = {r["url"] for r in out}
    assert urls == {"https://example.com/s/1", "https://example.com/r/1"}


def test_apply_merge_dedups_images_by_url():
    a = _listing(source="suumo", url="https://example.com/s/1",
                 suumo_images=[{"url": "https://img/1.jpg"}])
    b = _listing(source="homes", url="https://example.com/h/1",
                 suumo_images=[{"url": "https://img/1.jpg"}, {"url": "https://img/2.jpg"}])
    out = apply_dedup_results(
        [a, b],
        [DedupResult(idx_a=0, idx_b=1, same_unit=True, confidence=0.95, reasoning="同一")],
    )
    urls = [img["url"] for img in out[0]["suumo_images"]]
    assert urls == ["https://img/1.jpg", "https://img/2.jpg"]
