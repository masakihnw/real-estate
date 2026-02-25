#!/usr/bin/env python3
"""
投資スコア・掲載日数・競合物件数・価格履歴を付与するエンリッチャー。

asset_score をベースに投資判断に有用なメタデータを付与する。
"""

from datetime import datetime
from typing import Any, Optional

from report_utils import normalize_listing_name


def _building_group_key(listing: dict) -> str:
    """同一マンション判定用キー。物件名（正規化）+ 区名。"""
    name = normalize_listing_name(listing.get("name") or "")
    addr = listing.get("address") or ""
    ward = _extract_ward(addr)
    return f"{name}|{ward or ''}"


def _extract_ward(address: str) -> str:
    """住所から区名を抽出。"""
    if not address:
        return ""
    import re
    m = re.search(r"(?<=[都道府県])\S+?区", address)
    return m.group(0) if m else ""


def calculate_investment_score(listing: dict[str, Any]) -> float:
    """
    投資スコア（0-100）を算出する。
    asset_score の含み益率ベーススコアを使用。データ不足時は 0。
    """
    try:
        from asset_score import get_asset_score_and_rank
        score, _ = get_asset_score_and_rank(listing)
        return float(score)
    except Exception:
        return 0.0


def calculate_days_on_market(
    listing: dict,
    reference_date: Optional[datetime] = None,
) -> Optional[int]:
    """
    掲載日数を算出する（日数）。
    added_at（ISO 8601）または first_seen があれば reference_date との差分を返す。
    データなしの場合は None。
    """
    ref = reference_date or datetime.utcnow()
    added = listing.get("added_at") or listing.get("first_seen")
    if not added:
        return None
    if isinstance(added, str):
        try:
            from datetime import datetime as dt
            # ISO 8601 形式をパース
            if "T" in added:
                added_dt = dt.fromisoformat(added.replace("Z", "+00:00"))
            else:
                added_dt = dt.strptime(added[:10], "%Y-%m-%d")
            ref_naive = ref.replace(tzinfo=None) if ref.tzinfo else ref
            added_naive = added_dt.replace(tzinfo=None) if added_dt.tzinfo else added_dt
            delta = ref_naive - added_naive
            return max(0, delta.days)
        except (ValueError, TypeError):
            return None
    if hasattr(added, "days"):
        return max(0, added.days)
    return None


def count_competing_listings(listing: dict, all_listings: list[dict]) -> int:
    """
    同一マンション内の競合物件数をカウントする（自物件を含む）。
    building_group_key が一致する物件数を返す。
    """
    key = _building_group_key(listing)
    if not key.strip("|"):
        return 0
    count = 0
    for other in all_listings:
        if _building_group_key(other) == key:
            count += 1
    return count


def inject_price_history(listing: dict, history: list[dict]) -> dict:
    """
    価格履歴を listing に付与する。
    history は [{"date": "YYYY-MM-DD", "price_man": int}, ...] 形式。
    付与後は listing["price_history"] に格納される。
    """
    if not history:
        return listing
    listing = dict(listing)
    listing["price_history"] = [
        {"date": h.get("date"), "price_man": h.get("price_man")}
        for h in history
        if h.get("date") and h.get("price_man") is not None
    ]
    return listing


def enrich_investment_metadata(
    listing: dict,
    all_listings: Optional[list[dict]] = None,
    reference_date: Optional[datetime] = None,
) -> dict:
    """
    1物件に投資メタデータを付与する。
    - investment_score: 0-100
    - days_on_market: 掲載日数（日）
    - competing_listings: 競合物件数（all_listings 指定時のみ）
    """
    out = dict(listing)
    out["investment_score"] = calculate_investment_score(listing)
    dom = calculate_days_on_market(listing, reference_date)
    if dom is not None:
        out["days_on_market"] = dom
    if all_listings:
        out["competing_listings"] = count_competing_listings(listing, all_listings)
    return out
