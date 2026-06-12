"""claude_investment_summarizer の context 生成・キャッシュキーのテスト。"""

from claude_investment_summarizer import (
    _build_score_context,
    _building_units_signature,
    _listing_stable_key,
)


def _listing_with_units():
    return {
        "name": "パークタワー豊洲",
        "price_man": 9000,
        "area_m2": 70,
        "layout": "3LDK",
        "built_year": 2018,
        "address": "東京都江東区豊洲1",
        "building_units": [
            {"floor": 3, "area_m2": 60, "layout": "2LDK", "price_man": 8000,
             "direction": "南", "price_per_m2_man": 133.3, "url": "u2", "is_current": False},
            {"floor": 10, "area_m2": 70, "layout": "3LDK", "price_man": 9000,
             "direction": "東", "price_per_m2_man": 128.6, "url": "u1", "is_current": True},
        ],
    }


def test_context_includes_building_units_block():
    ctx = _build_score_context(_listing_with_units())
    assert "棟内の売出全戸" in ctx
    # 全戸が列挙され、自戸が ★ でマークされる
    assert "★" in ctx
    assert "8000万円" in ctx
    assert "9000万円" in ctx
    assert "棟内ベスト戸基準" in ctx


def test_context_skips_block_for_single_unit():
    listing = _listing_with_units()
    listing["building_units"] = None
    ctx = _build_score_context(listing)
    assert "棟内の売出全戸" not in ctx


def test_stable_key_changes_with_building_units():
    base = _listing_with_units()
    base["building_units"] = None
    key_single = _listing_stable_key(base)

    multi = _listing_with_units()
    key_multi = _listing_stable_key(multi)
    assert key_single != key_multi

    # 他戸の価格が変われば再分析されるようキーも変わる
    changed = _listing_with_units()
    changed["building_units"][0]["price_man"] = 7800
    assert _listing_stable_key(changed) != key_multi


def test_building_units_signature_none_for_single():
    assert _building_units_signature({"building_units": None}) is None
    assert _building_units_signature({"building_units": [{"floor": 1}]}) is None


def test_building_units_signature_handles_mixed_none_fields():
    # floor/area/price に None が混在しても TypeError にならず、順序非依存で安定する
    listing = {"building_units": [
        {"floor": None, "area_m2": 60, "price_man": 8000},
        {"floor": 3, "area_m2": None, "price_man": 8000},
        {"floor": 3, "area_m2": 70, "price_man": None},
    ]}
    sig = _building_units_signature(listing)
    assert sig is not None
    # 逆順でも同じシグネチャ（決定的ソート）
    reversed_listing = {"building_units": list(reversed(listing["building_units"]))}
    assert _building_units_signature(reversed_listing) == sig
