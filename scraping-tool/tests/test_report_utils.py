"""
report_utils の差分検出・キー・フォーマットのテスト。
identity_key（価格除く）で突合し、価格変動は updated になることを固定する。
"""
import pytest
from pathlib import Path

from report_utils import (
    _normalize_address_for_key,
    compare_listings,
    format_area,
    format_floor,
    format_ownership,
    format_price,
    format_walk,
    google_maps_link,
    google_maps_url,
    identity_key,
    listing_key,
    normalize_listing_name,
)


# --- normalize_listing_name ---


def test_normalize_listing_name_empty():
    assert normalize_listing_name("") == ""
    assert normalize_listing_name(None) == ""


def test_normalize_listing_name_spaces():
    """全角・半角スペースは除去され同一になる。"""
    a = "オープンレジデンス　祐天寺"
    b = "オープンレジデンス 祐天寺"
    c = "オープンレジデンス  祐天寺"
    assert normalize_listing_name(a) == normalize_listing_name(b)
    assert normalize_listing_name(b) == normalize_listing_name(c)
    assert " " not in normalize_listing_name(a)
    assert "　" not in normalize_listing_name(a)


# --- identity_key vs listing_key ---


def _listing(name="A", layout="2LDK", area_m2=65.0, price_man=8000, address="東京都目黒区", built_year=2020, station_line="祐天寺", walk_min=5):
    return {
        "name": name,
        "layout": layout,
        "area_m2": area_m2,
        "price_man": price_man,
        "address": address,
        "built_year": built_year,
        "station_line": station_line,
        "walk_min": walk_min,
    }


def test_identity_key_same_when_only_price_differs():
    """価格だけ違う場合は identity_key は同一（差分検出で updated にしたいため）。"""
    r1 = _listing(price_man=8000)
    r2 = _listing(price_man=7500)
    assert identity_key(r1) == identity_key(r2)


def test_listing_key_different_when_price_differs():
    """listing_key は価格を含むので、価格が違えば別キー。"""
    r1 = _listing(price_man=8000)
    r2 = _listing(price_man=7500)
    assert listing_key(r1) != listing_key(r2)


def test_identity_key_different_when_layout_differs():
    r1 = _listing(layout="2LDK")
    r2 = _listing(layout="3LDK")
    assert identity_key(r1) != identity_key(r2)


# --- compare_listings ---


def test_compare_listings_price_only_change_is_updated():
    """同一物件で価格だけ変わった場合は updated に入る（new/removed ではない）。"""
    prev = [_listing(name="マンションA", price_man=8000)]
    curr = [_listing(name="マンションA", price_man=7500)]
    result = compare_listings(curr, prev)
    assert len(result["new"]) == 0
    assert len(result["removed"]) == 0
    assert len(result["updated"]) == 1
    assert result["updated"][0]["current"]["price_man"] == 7500
    assert result["updated"][0]["previous"]["price_man"] == 8000
    assert len(result["unchanged"]) == 0


def test_compare_listings_new_removed_unchanged():
    """新規・削除・変更なしの基本ケース。"""
    prev = [
        _listing(name="A", price_man=8000),
        _listing(name="B", price_man=7000),
    ]
    curr = [
        _listing(name="A", price_man=8000),   # 変更なし
        _listing(name="C", price_man=9000),  # 新規
        # B は削除
    ]
    result = compare_listings(curr, prev)
    assert len(result["unchanged"]) == 1
    assert result["unchanged"][0]["name"] == "A"
    assert len(result["new"]) == 1
    assert result["new"][0]["name"] == "C"
    assert len(result["removed"]) == 1
    assert result["removed"][0]["name"] == "B"
    assert len(result["updated"]) == 0


def test_compare_listings_no_previous():
    """previous が None のときは current がすべて new。"""
    curr = [_listing(name="A")]
    result = compare_listings(curr, None)
    assert result["new"] == curr
    assert result["updated"] == []
    assert result["removed"] == []
    assert result["unchanged"] == []


# --- compare_listings: floor_position fallback ---


def _listing_with_floor(name="A", layout="2LDK", area_m2=65.0, price_man=8000,
                         address="東京都目黒区", built_year=2020, floor_position=None):
    return {
        "name": name, "layout": layout, "area_m2": area_m2,
        "price_man": price_man, "address": address,
        "built_year": built_year, "floor_position": floor_position,
        "station_line": "", "walk_min": 5,
    }


def test_compare_listings_floor_none_to_value_is_updated():
    """floor_position が None→値 に変わった場合は updated（not new+removed）。"""
    prev = [_listing_with_floor(name="アップルタワー", floor_position=None, price_man=11450)]
    curr = [_listing_with_floor(name="アップルタワー", floor_position=33, price_man=11450)]
    result = compare_listings(curr, prev)
    assert len(result["new"]) == 0
    assert len(result["removed"]) == 0
    assert len(result["updated"]) == 1


def test_compare_listings_floor_value_to_none_is_updated():
    """floor_position が値→None に変わった場合も updated。"""
    prev = [_listing_with_floor(name="ベイサイドタワー", floor_position=18, price_man=10980)]
    curr = [_listing_with_floor(name="ベイサイドタワー", floor_position=None, price_man=10980)]
    result = compare_listings(curr, prev)
    assert len(result["new"]) == 0
    assert len(result["removed"]) == 0
    assert len(result["updated"]) == 1


def test_compare_listings_floor_both_none_matches():
    """両方 floor_position=None なら完全一致で unchanged。"""
    prev = [_listing_with_floor(name="X", floor_position=None, price_man=8000)]
    curr = [_listing_with_floor(name="X", floor_position=None, price_man=8000)]
    result = compare_listings(curr, prev)
    assert len(result["unchanged"]) == 1
    assert len(result["new"]) == 0
    assert len(result["removed"]) == 0


def test_compare_listings_floor_different_values_are_different():
    """両方に階数がある場合（3階 vs 11階）は別ユニットとして扱う。"""
    prev = [_listing_with_floor(name="マンションA", floor_position=3, price_man=8000)]
    curr = [_listing_with_floor(name="マンションA", floor_position=11, price_man=9000)]
    result = compare_listings(curr, prev)
    assert len(result["new"]) == 1
    assert len(result["removed"]) == 1
    assert len(result["updated"]) == 0


def test_compare_listings_floor_fallback_with_price_change():
    """floor_position が None→値 + 価格変更 の場合も updated。"""
    prev = [_listing_with_floor(name="タワーX", floor_position=None, price_man=9000)]
    curr = [_listing_with_floor(name="タワーX", floor_position=5, price_man=8500)]
    result = compare_listings(curr, prev)
    assert len(result["new"]) == 0
    assert len(result["removed"]) == 0
    assert len(result["updated"]) == 1
    assert result["updated"][0]["current"]["price_man"] == 8500
    assert result["updated"][0]["previous"]["price_man"] == 9000


def test_compare_listings_floor_fallback_does_not_steal_exact_match():
    """完全一致の物件がある場合、フォールバックが横取りしないこと。"""
    prev = [
        _listing_with_floor(name="M", floor_position=5, price_man=8000),
        _listing_with_floor(name="M", floor_position=None, price_man=7000),
    ]
    curr = [
        _listing_with_floor(name="M", floor_position=5, price_man=8000),
        _listing_with_floor(name="M", floor_position=10, price_man=7000),
    ]
    result = compare_listings(curr, prev)
    assert len(result["unchanged"]) == 1
    assert len(result["updated"]) == 1
    assert len(result["new"]) == 0
    assert len(result["removed"]) == 0


# --- format 境界値 ---


def test_format_price():
    assert format_price(None) == "-"
    assert format_price(5000) == "5000万円"
    assert format_price(10000) == "1億円"
    assert format_price(15000) == "1億5000万円"


def test_format_area():
    assert format_area(None) == "-"
    assert format_area(65.0) == "65.0㎡"
    assert format_area(65.12) == "65.1㎡"


def test_format_walk():
    assert format_walk(None) == "-"
    assert format_walk(5) == "徒歩5分"


def test_format_floor():
    assert format_floor(None, None) == "階:-"
    assert format_floor(3, 10) == "3階/10階建"
    assert format_floor(3, None) == "3階"
    assert format_floor(None, 10) == "10階建"
    # 構造文字列がある場合は 所在階/構造 の形式
    assert format_floor(12, 13, "RC13階地下1階建") == "12階/RC13階地下1階建"
    assert format_floor(12, None, "RC13階地下1階建") == "12階/RC13階地下1階建"
    assert format_floor(None, None, "RC13階地下1階建") == "RC13階地下1階建"


def test_format_ownership():
    assert format_ownership(None) == "権利:不明"
    assert format_ownership("") == "権利:不明"
    assert format_ownership("   ") == "権利:不明"
    assert format_ownership("所有権") == "所有権"
    assert format_ownership("  借地権  ") == "借地権"
    # 一般定期借地権は詳細を省略して「一般定期借地権（賃借権）」のみ表示
    long_teiki = "一般定期借地権（賃借権）、借地期間残存59年8ヶ月、借地権設定登記不可、賃料改定は3年毎に改定、改定後賃料は公式による、借地権の譲渡・転貸可(転貸主承諾、承諾要、承諾料不要)"
    assert format_ownership(long_teiki) == "一般定期借地権（賃借権）"


# --- _normalize_address_for_key ---


def test_normalize_address_strips_tokyo_prefix():
    assert _normalize_address_for_key("東京都江東区東雲１") == "江東区東雲1"
    assert _normalize_address_for_key("東京都世田谷区上北沢５-13-2") == "世田谷区上北沢5"


def test_normalize_address_strips_chome_suffix():
    assert _normalize_address_for_key("江東区東雲1丁目") == "江東区東雲1"
    assert _normalize_address_for_key("板橋区加賀1丁目") == "板橋区加賀1"


def test_normalize_address_cross_site_match():
    """SUUMO と nomucom の住所が正規化後に一致すること。"""
    assert _normalize_address_for_key("東京都江東区東雲１") == _normalize_address_for_key("江東区東雲1丁目")
    assert _normalize_address_for_key("東京都板橋区加賀１") == _normalize_address_for_key("板橋区加賀1丁目")
    assert _normalize_address_for_key("東京都墨田区本所１") == _normalize_address_for_key("墨田区本所1丁目")


def test_normalize_address_empty():
    assert _normalize_address_for_key("") == ""
    assert _normalize_address_for_key(None) == ""


def test_google_maps_url():
    assert google_maps_url("") == ""
    assert google_maps_url("   ") == ""
    assert "google.com/maps" in google_maps_url("東京都練馬区東大泉１")
    assert "api=1" in google_maps_url("東京都練馬区東大泉１")
    assert "query=" in google_maps_url("東京都練馬区東大泉１")


def test_google_maps_link():
    assert google_maps_link("") == "-"
    assert google_maps_link("   ") == "-"
    assert "[Google Map]" in google_maps_link("東京都練馬区東大泉１")
    assert "google.com/maps" in google_maps_link("東京都練馬区東大泉１")