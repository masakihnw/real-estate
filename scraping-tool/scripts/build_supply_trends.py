#!/usr/bin/env python3
"""
供給トレンドデータの集計。

物件リストから区別・四半期別の供給件数を集計する。
"""

from collections import defaultdict
from typing import Any


def _extract_ward(address: str) -> str:
    """住所から区名を抽出。"""
    if not address:
        return ""
    import re
    m = re.search(r"(?<=[都道府県])\S+?区", address)
    return m.group(0) if m else ""


def _quarter_from_date(date_str: str) -> str:
    """YYYY-MM-DD または YYYY-MM から四半期ラベル (例: 2025Q1) を返す。"""
    if not date_str:
        return ""
    parts = date_str.strip()[:7].split("-")  # YYYY-MM
    if len(parts) >= 2:
        try:
            y, m = int(parts[0]), int(parts[1])
            q = (m - 1) // 3 + 1
            return f"{y}Q{q}"
        except ValueError:
            pass
    return ""


def aggregate_trends(listings: list[dict[str, Any]]) -> dict[str, Any]:
    """
    物件リストから供給トレンドを集計する。
    返却形式:
      {
        "by_ward": { "渋谷区": {"count": N, "quarters": {"2025Q1": M, ...}}, ... },
        "total_count": N,
        "quarters": ["2025Q1", "2025Q2", ...]
      }
    """
    result: dict[str, Any] = {
        "by_ward": {},
        "total_count": len(listings),
        "quarters": [],
    }

    if not listings:
        return result

    by_ward: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    all_quarters: set[str] = set()

    for listing in listings:
        ward = _extract_ward(listing.get("address") or "")
        if not ward:
            ward = "不明"
        added = listing.get("added_at") or listing.get("first_seen") or ""
        quarter = _quarter_from_date(added) if isinstance(added, str) else ""
        if not quarter:
            quarter = "未分類"
        by_ward[ward][quarter] += 1
        all_quarters.add(quarter)

    result["quarters"] = sorted(all_quarters)
    result["by_ward"] = {
        ward: {"count": sum(qvals.values()), "quarters": dict(qvals)}
        for ward, qvals in sorted(by_ward.items())
    }

    return result


def build_supply_trends(listings: list[dict[str, Any]]) -> dict[str, Any]:
    """
    aggregate_trends のエイリアス。空の入力でもエラーにならない。
    """
    return aggregate_trends(listings or [])
