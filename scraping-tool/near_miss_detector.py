"""
フィルタ漏れ候補（Near-miss）検出。
条件を1つだけ僅差で不合格の物件を検出し、見逃しを防ぐ。
"""

from __future__ import annotations

from config import (
    PRICE_MIN_MAN,
    PRICE_MAX_MAN,
    AREA_MIN_M2,
    AREA_MAX_M2,
    BUILT_YEAR_MIN,
    WALK_MIN_MAX,
    TOTAL_UNITS_MIN,
)
from parse_utils import layout_ok
from scraper_common import (
    load_station_passengers,
    station_passengers_ok,
    line_ok,
    is_tokyo_23_by_address,
)
from logger import get_logger

logger = get_logger(__name__)

# 各条件のマージン（条件不合格がこの範囲内なら "惜しい" と判定）
MARGINS = {
    "price_man": 500,      # 500万円のマージン（上下両方向）
    "area_m2": 3.0,        # 3㎡のマージン
    "walk_min": 2,         # 2分のマージン
    "built_year": 2,       # 2年のマージン
    "total_units": 5,      # 5戸のマージン
}


def _get_url(listing: dict) -> str:
    """listing から URL を取得する。dict / dataclass 両対応。"""
    if isinstance(listing, dict):
        return listing.get("url", "")
    return getattr(listing, "url", "")


def _get_field(listing: dict, key: str, default=None):
    """listing からフィールドを取得する。dict / dataclass 両対応。"""
    if isinstance(listing, dict):
        return listing.get(key, default)
    return getattr(listing, key, default)


def _to_dict(listing) -> dict:
    """listing を dict に変換する。既に dict ならそのまま返す。"""
    if isinstance(listing, dict):
        return dict(listing)
    # dataclass の場合
    if hasattr(listing, "__dataclass_fields__"):
        from dataclasses import asdict
        return asdict(listing)
    # NamedTuple / 一般オブジェクト
    if hasattr(listing, "_asdict"):
        return listing._asdict()
    return vars(listing)


def _check_conditions(listing) -> list[tuple[bool, str | None]]:
    """各フィルタ条件をチェックし、(合格か, 不合格時の理由文) のリストを返す。

    バイナリ条件（マージンなし）は合格/不合格のみ。
    数値条件はマージン内かどうかも判定する。

    Returns:
        list of (passed, reason_or_none)
        - passed=True: 条件を満たしている
        - passed=False, reason=None: 不合格かつマージン外（バイナリ条件 or 大幅に外れ）
        - passed=False, reason=str: 不合格だがマージン内（near-miss 候補の理由）
    """
    results: list[tuple[bool, str | None]] = []
    address = _get_field(listing, "address", "")
    station_line = _get_field(listing, "station_line", "")
    price_man = _get_field(listing, "price_man")
    area_m2 = _get_field(listing, "area_m2")
    layout = _get_field(listing, "layout", "")
    built_year = _get_field(listing, "built_year")
    walk_min = _get_field(listing, "walk_min")
    total_units = _get_field(listing, "total_units")

    passengers_map = load_station_passengers()

    # --- バイナリ条件（マージンなし） ---

    # 1. 東京23区判定
    results.append((is_tokyo_23_by_address(address), None))

    # 2. 路線フィルタ
    results.append((line_ok(station_line, empty_passes=False), None))

    # 3. 駅乗降客数
    results.append((station_passengers_ok(station_line, passengers_map), None))

    # 6. 間取り
    results.append((layout_ok(layout), None))

    # --- 数値条件（マージンあり） ---

    # 4. 価格
    price_margin = MARGINS["price_man"]
    if price_man is not None:
        if price_man < PRICE_MIN_MAN or price_man > PRICE_MAX_MAN:
            # 不合格 — マージン内か判定
            reason = None
            if price_man < PRICE_MIN_MAN:
                diff = PRICE_MIN_MAN - price_man
                if diff <= price_margin:
                    reason = f"価格: {price_man:,}万円 (下限-{diff:,}万)"
            elif price_man > PRICE_MAX_MAN:
                diff = price_man - PRICE_MAX_MAN
                if diff <= price_margin:
                    reason = f"価格: {price_man:,}万円 (上限+{diff:,}万)"
            results.append((False, reason))
        else:
            results.append((True, None))
    else:
        # 値なし → 判定不能 → 合格扱い
        results.append((True, None))

    # 5. 面積
    area_margin = MARGINS["area_m2"]
    if area_m2 is not None:
        failed = False
        reason = None
        if area_m2 < AREA_MIN_M2:
            failed = True
            diff = AREA_MIN_M2 - area_m2
            if diff <= area_margin:
                reason = f"面積: {area_m2}㎡ (下限-{diff:.1f}㎡)"
        elif AREA_MAX_M2 is not None and area_m2 > AREA_MAX_M2:
            failed = True
            diff = area_m2 - AREA_MAX_M2
            if diff <= area_margin:
                reason = f"面積: {area_m2}㎡ (上限+{diff:.1f}㎡)"
        if failed:
            results.append((False, reason))
        else:
            results.append((True, None))
    else:
        results.append((True, None))

    # 7. 築年
    built_margin = MARGINS["built_year"]
    if built_year is not None:
        if built_year < BUILT_YEAR_MIN:
            diff = BUILT_YEAR_MIN - built_year
            reason = None
            if diff <= built_margin:
                reason = f"築年: {built_year}年 (下限-{diff}年)"
            results.append((False, reason))
        else:
            results.append((True, None))
    else:
        results.append((True, None))

    # 8. 徒歩
    walk_margin = MARGINS["walk_min"]
    if walk_min is not None:
        if walk_min > WALK_MIN_MAX:
            diff = walk_min - WALK_MIN_MAX
            reason = None
            if diff <= walk_margin:
                reason = f"徒歩: {walk_min}分 (上限+{diff}分)"
            results.append((False, reason))
        else:
            results.append((True, None))
    else:
        results.append((True, None))

    # 9. 総戸数
    units_margin = MARGINS["total_units"]
    if total_units is not None:
        if total_units < TOTAL_UNITS_MIN:
            diff = TOTAL_UNITS_MIN - total_units
            reason = None
            if diff <= units_margin:
                reason = f"総戸数: {total_units}戸 (下限-{diff}戸)"
            results.append((False, reason))
        else:
            results.append((True, None))
    else:
        results.append((True, None))

    return results


def detect_near_misses(
    all_listings: list[dict],
    passed_listings: list[dict],
) -> list[dict]:
    """フィルタ漏れ候補（Near-miss）を検出する。

    all_listings: apply_conditions前の全物件（各スクレイパーのparse結果）
    passed_listings: apply_conditions後のフィルタ通過物件

    Returns:
        near-miss候補リスト。各dictに near_miss=True,
        near_miss_reasons=["価格: 15,200万円 (上限+200万)"] を付与。
    """
    passed_urls: set[str] = {_get_url(p) for p in passed_listings}

    near_misses: list[dict] = []
    for listing in all_listings:
        url = _get_url(listing)
        if not url or url in passed_urls:
            continue

        checks = _check_conditions(listing)

        # 不合格の条件を集計
        fail_count = 0
        margin_reasons: list[str] = []
        has_binary_fail = False

        for passed, reason in checks:
            if not passed:
                fail_count += 1
                if reason is not None:
                    margin_reasons.append(reason)
                else:
                    # バイナリ条件の不合格、またはマージン外の数値条件
                    has_binary_fail = True

        # near-miss 判定: ちょうど1条件のみ不合格 & その条件がマージン内
        if fail_count == 1 and not has_binary_fail and len(margin_reasons) == 1:
            result = _to_dict(listing)
            result["near_miss"] = True
            result["near_miss_reasons"] = margin_reasons
            near_misses.append(result)

    if near_misses:
        logger.info("Near-miss候補: %d 件検出", len(near_misses))
    else:
        logger.info("Near-miss候補: なし")

    return near_misses
