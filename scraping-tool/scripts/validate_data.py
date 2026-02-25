#!/usr/bin/env python3
"""
物件データのバリデーション。

必須フィールド・異常値・重複の検出を行う。
"""

from dataclasses import dataclass, field
from typing import Any


@dataclass
class ValidationResult:
    """バリデーション結果。"""
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def has_errors(self) -> bool:
        return len(self.errors) > 0

    @property
    def has_warnings(self) -> bool:
        return len(self.warnings) > 0


def validate_listings(listings: list[dict[str, Any]]) -> ValidationResult:
    """
    物件リストをバリデーションする。
    - 空のリストはエラー
    - 必須フィールド（url, name, price_man, address）の欠損は警告またはエラー
    - 価格の異常値（負値・0・極端に高額）は警告
    - 重複URLは警告
    """
    result = ValidationResult()

    if not listings:
        result.errors.append("物件リストが空です")
        return result

    seen_urls: set[str] = set()

    for i, listing in enumerate(listings):
        idx = i + 1

        # URL チェック
        url = (listing.get("url") or "").strip()
        if not url:
            result.warnings.append(f"物件 {idx}: URL が空です")
        else:
            if url in seen_urls:
                result.warnings.append(f"物件 {idx}: 重複URL ({url[:50]}...)")
            seen_urls.add(url)

        # 必須フィールド
        name = (listing.get("name") or "").strip()
        if not name:
            result.warnings.append(f"物件 {idx}: 物件名が空です")

        price = listing.get("price_man")
        if price is None:
            result.warnings.append(f"物件 {idx}: 価格(price_man)が未設定です")
        elif isinstance(price, (int, float)):
            if price < 0:
                result.warnings.append(f"物件 {idx}: 価格が負の値です ({price})")
            elif price == 0 and url:
                result.warnings.append(f"物件 {idx}: 価格が0です（価格未定の可能性）")
            elif price > 100000:  # 1億円超は異常値の可能性
                result.warnings.append(f"物件 {idx}: 価格が異常に高額です ({price}万円)")

        address = (listing.get("address") or "").strip()
        if not address:
            result.warnings.append(f"物件 {idx}: 住所が空です")

    return result
