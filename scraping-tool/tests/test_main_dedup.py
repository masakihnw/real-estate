"""main.py の dedupe_listings / _merge_images の特性テスト（refactor Phase 1 安全網）。

既存挙動をそのまま固定する characterization test。
3段階 dedup（listing_key 完全一致 → クロスサイトファジー → 同一建物内マージ）の
代表選出・duplicate_count・alt_urls・画像マージの現仕様を検証する。
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import _merge_images, dedupe_listings  # noqa: E402


def _listing(**overrides) -> dict:
    """テスト用の最小リスティング。listing_key 構成フィールドを揃える。"""
    base = {
        "name": "パークタワー晴海",
        "layout": "3LDK",
        "area_m2": 70.5,
        "price_man": 9800,
        "address": "東京都中央区晴海2丁目3-1",
        "built_year": 2019,
        "source": "suumo",
        "url": "https://example.com/suumo/1",
        "property_type": "chuko",
        "floor_position": 10,
    }
    base.update(overrides)
    return base


# ─────────────────────── 1次判定: listing_key 完全一致 ───────────────────────


def test_stage1_exact_duplicates_merged_with_count_and_alt_urls():
    a = _listing(url="https://example.com/suumo/1", source="suumo")
    b = _listing(url="https://example.com/homes/1", source="homes")
    out = dedupe_listings([a, b])
    assert len(out) == 1
    rep = out[0]
    assert rep["duplicate_count"] == 2
    # 代表以外の URL とソースが alt_* に入る
    assert len(rep["alt_urls"]) == 1
    assert len(rep["alt_sources"]) == 1
    urls = {rep["url"], rep["alt_urls"][0]}
    assert urls == {"https://example.com/suumo/1", "https://example.com/homes/1"}


def test_stage1_representative_is_most_complete_row():
    sparse = _listing(url="https://example.com/a", total_units=None, station_line=None)
    rich = _listing(
        url="https://example.com/b",
        source="homes",
        total_units=200,
        station_line="大江戸線勝どき",
    )
    out = dedupe_listings([sparse, rich])
    assert len(out) == 1
    # 非 None フィールドが多い rich が代表になる
    assert out[0]["url"] == "https://example.com/b"


def test_stage1_distinct_listings_not_merged():
    a = _listing()
    b = _listing(price_man=10800, url="https://example.com/suumo/2")  # 価格違い
    out = dedupe_listings([a, b])
    assert len(out) == 2
    assert all(r["duplicate_count"] == 1 for r in out)


def test_stage1_singleton_has_no_alt_urls():
    out = dedupe_listings([_listing()])
    assert len(out) == 1
    assert out[0]["duplicate_count"] == 1
    assert "alt_urls" not in out[0]
    assert "alt_sources" not in out[0]


# ─────────────────────── 2次判定: クロスサイトファジー ───────────────────────


def test_stage1_brand_prefix_normalized_into_same_key():
    """ブランド接頭辞（三井）は normalize_listing_name で除去され、1次判定で統合される。"""
    a = _listing(name="パークタワー晴海", source="suumo", url="https://example.com/s/1")
    b = _listing(name="三井パークタワー晴海", source="homes", url="https://example.com/h/1")
    out = dedupe_listings([a, b])
    assert len(out) == 1
    rep = out[0]
    assert rep["duplicate_count"] == 2
    assert len(rep["alt_urls"]) == 1


def test_stage2_fuzzy_merges_cross_site_name_variants():
    """正規化後も名前が異なる表記揺れ（棟名サフィックス等）は、ソースが異なり
    面積・築年・住所が一致すればファジー判定で統合される。
    ファジー判定は価格を見ないため、価格差があっても統合される（現仕様）。"""
    a = _listing(
        name="パークタワー晴海", source="suumo", price_man=9800, url="https://example.com/s/1"
    )
    b = _listing(
        name="パークタワー晴海イースト",
        source="homes",
        price_man=9900,
        url="https://example.com/h/1",
    )
    out = dedupe_listings([a, b])
    assert len(out) == 1
    rep = out[0]
    assert rep["duplicate_count"] == 2
    assert len(rep["alt_urls"]) == 1


def test_stage2_fuzzy_does_not_merge_same_source():
    """同一ソース内の表記揺れはファジー統合しない（現仕様）。"""
    a = _listing(
        name="パークタワー晴海", source="suumo", price_man=9800, url="https://example.com/s/1"
    )
    b = _listing(
        name="パークタワー晴海イースト",
        source="suumo",
        price_man=9900,
        url="https://example.com/s/2",
    )
    out = dedupe_listings([a, b])
    assert len(out) == 2


def test_stage2_fuzzy_requires_same_area_and_built_year():
    a = _listing(
        name="パークタワー晴海", source="suumo", price_man=9800, url="https://example.com/s/1"
    )
    b = _listing(
        name="パークタワー晴海イースト",
        source="homes",
        price_man=9900,
        url="https://example.com/h/1",
        area_m2=75.0,  # 面積が違えば別物件
    )
    out = dedupe_listings([a, b])
    assert len(out) == 2


# ─────────────────────── 3次判定: 同一建物内マージ ───────────────────────


def test_stage3_same_building_same_area_floor_price_merged():
    """同一建物・同一 (面積, 階, 価格) は間取り表記が違っても1戸とみなす。"""
    a = _listing(layout="2LDK", url="https://example.com/s/1")
    b = _listing(layout="2DK", url="https://example.com/s/2")  # listing_key は別
    out = dedupe_listings([a, b])
    assert len(out) == 1
    assert out[0]["duplicate_count"] == 2


def test_stage3_floor_none_acts_as_wildcard():
    """floor_position=None は同一 (面積, 価格) の既存グループにマッチする。"""
    a = _listing(layout="2LDK", floor_position=5, url="https://example.com/s/1")
    b = _listing(layout="2DK", floor_position=None, url="https://example.com/s/2")
    out = dedupe_listings([a, b])
    assert len(out) == 1
    assert out[0]["duplicate_count"] == 2


def test_stage3_different_floor_not_merged():
    a = _listing(layout="2LDK", floor_position=5, url="https://example.com/s/1")
    b = _listing(layout="2DK", floor_position=12, url="https://example.com/s/2")
    out = dedupe_listings([a, b])
    assert len(out) == 2


def test_stage3_duplicate_count_is_summed_across_stages():
    """1次で2戸にまとまったグループが3次でさらに統合されると戸数は合算される。"""
    a1 = _listing(layout="2LDK", source="suumo", url="https://example.com/s/1")
    a2 = _listing(layout="2LDK", source="homes", url="https://example.com/h/1")
    b = _listing(layout="2DK", source="suumo", url="https://example.com/s/2")
    out = dedupe_listings([a1, a2, b])
    assert len(out) == 1
    assert out[0]["duplicate_count"] == 3


# ─────────────────────── _merge_images ───────────────────────


def test_merge_images_floor_plan_kept_if_representative_has_one():
    rep = {"floor_plan_images": ["https://img/fp_rep.jpg"], "suumo_images": []}
    other = {"floor_plan_images": ["https://img/fp_other.jpg"], "suumo_images": []}
    _merge_images(rep, [other])
    assert rep["floor_plan_images"] == ["https://img/fp_rep.jpg"]


def test_merge_images_floor_plan_takes_only_first_when_missing():
    rep = {"floor_plan_images": [], "suumo_images": []}
    other = {
        "floor_plan_images": ["https://img/fp1.jpg", "https://img/fp2.jpg"],
        "suumo_images": [],
    }
    _merge_images(rep, [other])
    # 1枚あれば十分（現仕様: 最初の1枚だけ取り込む）
    assert rep["floor_plan_images"] == ["https://img/fp1.jpg"]


def test_merge_images_photos_merged_with_url_dedup():
    rep = {
        "floor_plan_images": [],
        "suumo_images": [{"url": "https://img/p1.jpg", "caption": "外観"}],
    }
    other = {
        "floor_plan_images": [],
        "suumo_images": [
            {"url": "https://img/p1.jpg", "caption": "外観(重複)"},
            {"url": "https://img/p2.jpg", "caption": "リビング"},
        ],
    }
    _merge_images(rep, [other])
    urls = [img["url"] for img in rep["suumo_images"]]
    assert urls == ["https://img/p1.jpg", "https://img/p2.jpg"]


def test_merge_images_handles_missing_keys():
    rep = {}
    other = {"suumo_images": [{"url": "https://img/p1.jpg"}]}
    _merge_images(rep, [other])
    assert [img["url"] for img in rep["suumo_images"]] == ["https://img/p1.jpg"]
