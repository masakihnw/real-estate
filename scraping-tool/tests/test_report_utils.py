"""
report_utils の差分検出・キー・フォーマットのテスト。
identity_key（価格除く）で突合し、価格変動は updated になることを固定する。
"""
import pytest
from pathlib import Path

from report_utils import (
    _is_feature_tag,
    _normalize_address_for_key,
    clean_listing_name,
    compare_listings,
    format_area,
    format_floor,
    format_ownership,
    format_price,
    format_walk,
    google_maps_link,
    google_maps_url,
    identity_key,
    identity_key_str,
    inject_building_units,
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


def test_normalize_name_bracket_with_feature_tags():
    """【建物名】feature×feature×feature → 建物名"""
    assert normalize_listing_name("【クレヴィア住吉】ペット可×南向き×2015年築") == "クレヴィア住吉"


def test_normalize_name_bracket_with_partial_features():
    """【...】の後に建物名+特徴が混在 → 建物名部分が残る"""
    result = normalize_listing_name("【売主物件】パークホームズ 南向き")
    assert "パークホームズ" in result


def test_normalize_name_multiply_sign_in_name():
    """×が物件名の一部として使われている場合は保持"""
    result = normalize_listing_name("Aタワー×Bタワー")
    assert "×" in result


def test_normalize_name_goshitsu_suffix():
    """号室 suffix is stripped"""
    assert normalize_listing_name("クレヴィア住吉601号室") == "クレヴィア住吉"


def test_normalize_name_goshitsu_same_as_base():
    """号室付きと基本名は同一 normalized_name"""
    a = normalize_listing_name("クレヴィア住吉601号室")
    b = normalize_listing_name("クレヴィア住吉")
    assert a == b


def test_normalize_name_chome_suffix():
    """丁目 suffix is stripped"""
    a = normalize_listing_name("THEパームス高田馬場四丁目")
    b = normalize_listing_name("THEパームス高田馬場")
    assert a == b


def test_normalize_name_star_separated():
    """☆以降の広告テキストは除去される"""
    a = normalize_listing_name("東中野桜山レジデンス☆5路線3駅利用可能☆三菱地所レ…")
    b = normalize_listing_name("東中野桜山レジデンス")
    assert a == b


def test_normalize_name_year_built_tag():
    """2015年築 is recognized as a feature tag"""
    assert _is_feature_tag("2015年築")


def test_normalize_name_dash_variant_in_katakana():
    """カタカナ間の長音異体字（ー/―/-）は「ー」に統一され、別表記重複を吸収する。

    実データ id=174008/174075/174186（サンクレイドルレヴィール池袋）が
    ー(U+30FC) / ―(U+2015) / -(U+002D) で別物件化していたケース。
    """
    canonical = normalize_listing_name("サンクレイドルレヴィール池袋")  # ー U+30FC
    horizontal_bar = normalize_listing_name("サンクレイドルレヴィ―ル池袋")  # ― U+2015
    hyphen = normalize_listing_name("サンクレイドルレヴィ-ル池袋")  # - U+002D
    assert canonical == horizontal_bar == hyphen == "サンクレイドルレヴィール池袋"


def test_normalize_name_dash_variant_not_touching_digits():
    """数字に隣接するハイフンは長音化しない（住所・棟番号を壊さない）。"""
    assert "ー2" not in normalize_listing_name("ライオンズ-2")


def test_normalize_name_strips_promo_between_markers():
    """※...※ で囲まれた販促コピーは物件名から除去される。

    実データ id=174073「※池袋駅まで直通8分※桜並木沿いに…」のケース。
    """
    result = normalize_listing_name("※池袋駅まで直通8分※ パークハウス練馬")
    assert result == "パークハウス練馬"
    assert normalize_listing_name("パークハウス練馬 ※即入居可") == "パークハウス練馬"


def test_normalize_name_known_alias_toyosu():
    """英語表記の THE TOYOSU TOWER は正準名「ザ豊洲タワー」に統一される。

    実データ id=6823/174639/220938（英語）と id=192096（日本語）の分裂吸収。
    """
    # 全角ローマ字
    assert normalize_listing_name("ＴＨＥ　ＴＯＹＯＳＵ　ＴＯＷＥＲ") == "ザ豊洲タワー"
    # 半角 + 括弧内の日本語別名（括弧は除去され、エイリアスで復元）
    assert normalize_listing_name("THE TOYOSU TOWER (ザ・豊洲タワー)") == "ザ豊洲タワー"
    # 階数付き
    assert normalize_listing_name("THE TOYOSU TOWER 15階") == "ザ豊洲タワー"
    # 既に日本語表記ならそのまま
    assert normalize_listing_name("ザ豊洲タワー") == "ザ豊洲タワー"


def test_normalize_name_typo_misawa_homes():
    """OCR/誤記「ミサワホーズ」は「ミサワホームズ」に補正される（実データ id=272763）。"""
    a = normalize_listing_name("ミサワホーズ東大井")
    b = normalize_listing_name("ミサワホームズ東大井")
    assert a == b == "ミサワホームズ東大井"


def test_normalize_name_leading_the_article():
    """先頭の英語冠詞 THE はカタカナ名で「ザ」に統一される（実データ 174096/266409）。"""
    a = normalize_listing_name("THEパームス西戸山")
    b = normalize_listing_name("ザ・パームス西戸山")
    assert a == b == "ザパームス西戸山"
    # 大文字小文字を問わない
    assert normalize_listing_name("Theパークハウス") == "ザパークハウス"


def test_normalize_name_leading_the_not_romaji():
    """full ローマ字名（THE の後がカタカナでない）は THE→ザ 変換しない（エイリアス側で処理）。"""
    # THETOYOSUTOWER は T が続くため THE→ザ にならず、エイリアスで「ザ豊洲タワー」に
    assert normalize_listing_name("THE TOYOSU TOWER") == "ザ豊洲タワー"


def test_strip_name_brackets_trailing_tag():
    """末尾の【リノベ】等の装飾タグは除去される（実データ 174246/250868）。"""
    from report_utils import strip_name_brackets
    assert strip_name_brackets("テラス加賀　【リノベ】") == "テラス加賀"
    assert strip_name_brackets("コスモ東京ベイタワー　【リノベ】") == "コスモ東京ベイタワー"


def test_strip_name_brackets_leading_building_name():
    """先頭【建物名】+キャッチコピーは括弧内の建物名を採用（実データ 97870）。"""
    from report_utils import strip_name_brackets
    assert strip_name_brackets(
        "【マーク・ゼロワン曳舟タワー】駅近好立地　スカイツリ…"
    ) == "マーク・ゼロワン曳舟タワー"


def test_strip_name_brackets_noops_and_failsafe():
    """ブラケットが無ければそのまま。空になる場合は元名を返す。"""
    from report_utils import strip_name_brackets
    assert strip_name_brackets("プラウド目黒") == "プラウド目黒"
    assert strip_name_brackets("オープンレジデンス 祐天寺") == "オープンレジデンス 祐天寺"
    # 括弧内が特徴タグ（先頭）なら後続を採用
    assert strip_name_brackets("【ペット可】パークハウス南向き") == "パークハウス南向き"
    # 全体が【】のみ → 元名フォールバック
    assert strip_name_brackets("【リノベ】") == "【リノベ】"


def test_normalize_name_dash_katakana_kanji_boundary():
    """カタカナと漢字の境界の長音異体字も「ー」に統一（実データ 250872/282092）。"""
    a = normalize_listing_name("ゼファー浅草馬道通り")   # ー U+30FC
    b = normalize_listing_name("ゼファ―浅草馬道通り")   # ― U+2015
    assert a == b == "ゼファー浅草馬道通り"


def test_normalize_name_dash_before_alnum_preserved():
    """カタカナ直後でも後続が英数字なら棟番号扱いで変換しない。"""
    assert "ー" not in normalize_listing_name("メゾン-101")
    assert normalize_listing_name("コーポ-A") == "コーポ-A"


def test_normalize_name_strips_area_suffix():
    """「建物名/補足地名」の補足地名サフィックスを除去（実データ 174008/278352）。"""
    a = normalize_listing_name("サンクレイドルレヴィール池袋")
    b = normalize_listing_name("サンクレイドルレヴィール池袋/上池袋２丁目")
    assert a == b == "サンクレイドルレヴィール池袋"


# --- clean_listing_name ---


def test_clean_listing_name_compound_feature_tags():
    """×区切りの複合特徴タグは物件名ではない → 空"""
    assert clean_listing_name("ペット可×南向き×2015年築") == ""


def test_clean_listing_name_year_built():
    """単独の年築タグは物件名ではない → 空"""
    assert clean_listing_name("2015年築") == ""


def test_clean_listing_name_normal_name():
    """通常の物件名はそのまま返る"""
    assert clean_listing_name("クレヴィア住吉") == "クレヴィア住吉"


def test_clean_listing_name_page_title():
    """ページタイトル文言（物件一覧）は物件名ではない → 空"""
    assert clean_listing_name("東京都の新築マンション・分譲マンション物件一覧") == ""


def test_clean_listing_name_page_title_partial():
    """物件一覧を含む文字列は全て弾く"""
    assert clean_listing_name("中古マンション物件一覧") == ""


def test_clean_listing_name_button_text():
    """UIボタン文言は物件名ではない → 空"""
    assert clean_listing_name("見学予約") == ""
    assert clean_listing_name("資料請求") == ""
    assert clean_listing_name("お気に入り") == ""
    assert clean_listing_name("詳細を見る") == ""
    assert clean_listing_name("noimage") == ""


def test_clean_listing_name_diamond_wrapped():
    """◆NAME◆ の装飾記号を除去して物件名だけ返す"""
    assert clean_listing_name("◆ザ・パークハウス弦巻◆") == "ザ・パークハウス弦巻"


def test_clean_listing_name_diamond_leading_only():
    """先頭の◆だけ付いている場合も除去"""
    assert clean_listing_name("◆パークタワー晴海") == "パークタワー晴海"


def test_clean_listing_name_decorative_symbols():
    """■□☆★♪ などの装飾記号を先頭末尾から除去"""
    assert clean_listing_name("★プラウド目黒★") == "プラウド目黒"
    assert clean_listing_name("■□パークシティ武蔵小山") == "パークシティ武蔵小山"
    assert clean_listing_name("ブリリア有明♪") == "ブリリア有明"


def test_clean_listing_name_normal_unchanged():
    """装飾のない通常名称はそのまま返す"""
    assert clean_listing_name("ザ・パークハウス弦巻") == "ザ・パークハウス弦巻"


# --- identity_key_str: area_m2 formatting ---


def test_identity_key_str_area_float_int_consistent():
    """area_m2 70.0 (float) と 70 (int) で同一 identity_key_str"""
    r1 = _listing(area_m2=70.0)
    r2 = _listing(area_m2=70)
    assert identity_key_str(r1) == identity_key_str(r2)


def test_identity_key_str_area_decimal_preserved():
    """area_m2 69.66 の小数部は保持"""
    r = _listing(area_m2=69.66)
    assert "69.66" in identity_key_str(r)


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

# --- inject_building_units ---


def _bu_listing(name, ward_addr, url, price=None, floor=None, area=None, layout=None, direction=None):
    return {
        "name": name,
        "address": ward_addr,
        "url": url,
        "price_man": price,
        "floor_position": floor,
        "area_m2": area,
        "layout": layout,
        "direction": direction,
    }


def test_inject_building_units_single_unit_is_none():
    rows = [_bu_listing("パークタワー", "東京都江東区豊洲1", "u1", price=8000, area=60)]
    inject_building_units(rows)
    assert rows[0]["building_units"] is None
    assert rows[0]["building_group_key"] is None


def test_inject_building_units_groups_same_building():
    rows = [
        _bu_listing("パークタワー", "東京都江東区豊洲1", "u1", price=9000, floor=10, area=70, layout="3LDK"),
        _bu_listing("パークタワー", "東京都江東区豊洲1", "u2", price=8000, floor=3, area=60, layout="2LDK"),
        _bu_listing("別マンション", "東京都江東区豊洲1", "u3", price=8500, floor=5, area=65),
    ]
    inject_building_units(rows)

    # 同一建物の2戸は building_units を持ち、別マンションは None
    assert rows[0]["building_units"] is not None
    assert rows[1]["building_units"] is not None
    assert rows[2]["building_units"] is None
    assert rows[0]["building_group_key"] == rows[1]["building_group_key"]

    # 全戸（自分含む）が価格昇順で入る
    units = rows[0]["building_units"]
    assert len(units) == 2
    assert [u["price_man"] for u in units] == [8000, 9000]
    # is_current は評価対象の戸だけ True
    current = [u for u in units if u["is_current"]]
    assert len(current) == 1
    assert current[0]["url"] == "u1"
    # ㎡単価が計算される
    assert units[1]["price_per_m2_man"] == round(9000 / 70, 1)


def test_inject_building_units_self_always_included_when_capped():
    # 上限(12)を超える戸数でも、評価対象の自分は必ず含まれる
    rows = [
        _bu_listing("メガタワー", "東京都港区港南2", f"u{i}", price=7000 + i * 100, floor=i, area=60)
        for i in range(15)
    ]
    inject_building_units(rows)
    # 最高価格（自分が末尾）の戸でも is_current が必ず1つ存在する
    target = max(rows, key=lambda r: r["price_man"])
    units = target["building_units"]
    assert any(u["is_current"] for u in units)
    assert sum(1 for u in units if u["is_current"]) == 1
