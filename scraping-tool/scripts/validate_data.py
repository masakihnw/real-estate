#!/usr/bin/env python3
"""
データ品質バリデーション。
latest.json のデータ品質を検証し、問題を報告する。
CI/CD パイプラインで使用してデータ劣化を検知する。
"""

import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

try:
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from report_utils import identity_key, normalize_listing_name
except ImportError:
    pass


class ValidationResult:
    def __init__(self):
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.stats: dict[str, Any] = {}

    @property
    def ok(self) -> bool:
        return len(self.errors) == 0

    def add_error(self, msg: str):
        self.errors.append(msg)

    def add_warning(self, msg: str):
        self.warnings.append(msg)

    def report(self) -> str:
        lines = []
        if self.errors:
            lines.append(f"## エラー ({len(self.errors)}件)")
            for e in self.errors:
                lines.append(f"- ❌ {e}")
        if self.warnings:
            lines.append(f"## 警告 ({len(self.warnings)}件)")
            for w in self.warnings:
                lines.append(f"- ⚠ {w}")
        lines.append(f"## 統計")
        for k, v in self.stats.items():
            lines.append(f"- {k}: {v}")
        return "\n".join(lines)


def validate_listings(listings: list[dict], label: str = "中古") -> ValidationResult:
    """物件リストのバリデーション。"""
    result = ValidationResult()

    if not listings:
        result.add_error(f"{label}: 物件が0件です")
        return result

    result.stats["total"] = len(listings)

    # 必須フィールド検証
    required_fields = ["url", "name", "price_man", "address"]
    for field in required_fields:
        missing = sum(1 for r in listings if not r.get(field))
        if missing > 0:
            pct = missing / len(listings) * 100
            if pct > 50:
                result.add_error(f"{label}: {field} が {missing}/{len(listings)}件 ({pct:.0f}%) 欠損")
            elif pct > 10:
                result.add_warning(f"{label}: {field} が {missing}/{len(listings)}件 ({pct:.0f}%) 欠損")

    # 価格の妥当性
    prices = [r["price_man"] for r in listings if r.get("price_man")]
    if prices:
        avg_price = sum(prices) / len(prices)
        result.stats[f"avg_price_man"] = int(avg_price)
        result.stats[f"price_range"] = f"{min(prices)}〜{max(prices)}万円"
        if avg_price < 1000 or avg_price > 50000:
            result.add_warning(f"{label}: 平均価格が異常 ({avg_price:.0f}万円)")

    # 面積の妥当性
    areas = [r["area_m2"] for r in listings if r.get("area_m2")]
    if areas:
        avg_area = sum(areas) / len(areas)
        result.stats[f"avg_area_m2"] = round(avg_area, 1)
        if avg_area < 10 or avg_area > 500:
            result.add_warning(f"{label}: 平均面積が異常 ({avg_area:.1f}m²)")

    # 重複検出
    url_counts = Counter(r.get("url") for r in listings if r.get("url"))
    duplicates = {url: count for url, count in url_counts.items() if count > 1}
    if duplicates:
        result.add_warning(f"{label}: URL 重複 {len(duplicates)}件")

    # identity_key 衝突
    try:
        key_counts = Counter(identity_key(r) for r in listings)
        collisions = sum(1 for count in key_counts.values() if count > 1)
        if collisions > 0:
            result.stats[f"identity_key_collisions"] = collisions
    except Exception:
        pass

    # 座標検証
    geo_count = sum(1 for r in listings if r.get("latitude") and r.get("longitude"))
    result.stats[f"geocoded"] = f"{geo_count}/{len(listings)} ({geo_count/len(listings)*100:.0f}%)"

    # 住まいサーフィンデータ率
    ss_count = sum(1 for r in listings if r.get("ss_lookup_status") == "found")
    result.stats[f"sumai_surfin"] = f"{ss_count}/{len(listings)} ({ss_count/len(listings)*100:.0f}%)"

    # ハザード情報率
    hazard_count = sum(1 for r in listings if r.get("hazard_info"))
    result.stats[f"hazard_info"] = f"{hazard_count}/{len(listings)} ({hazard_count/len(listings)*100:.0f}%)"

    # 物件名の空文字
    empty_names = sum(1 for r in listings if not (r.get("name") or "").strip())
    if empty_names > 0:
        result.add_warning(f"{label}: 物件名が空 {empty_names}件")

    return result


def validate_consistency(current: list[dict], previous: list[dict]) -> ValidationResult:
    """前回データとの整合性を検証。"""
    result = ValidationResult()

    current_count = len(current)
    previous_count = len(previous)

    if previous_count == 0:
        return result

    change_pct = abs(current_count - previous_count) / previous_count * 100
    result.stats["count_change"] = f"{previous_count} → {current_count} ({'+' if current_count >= previous_count else ''}{current_count - previous_count})"

    if change_pct > 50:
        result.add_error(f"物件数が前回比 {change_pct:.0f}% 変動 ({previous_count} → {current_count})")
    elif change_pct > 25:
        result.add_warning(f"物件数が前回比 {change_pct:.0f}% 変動 ({previous_count} → {current_count})")

    return result


def main():
    import argparse
    parser = argparse.ArgumentParser(description="データ品質バリデーション")
    parser.add_argument("input", help="検証する JSON ファイル")
    parser.add_argument("--previous", help="前回データ（整合性検証用）")
    parser.add_argument("--label", default="中古", help="ラベル")
    parser.add_argument("--strict", action="store_true", help="エラーがあれば exit 1")
    args = parser.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        listings = json.load(f)

    result = validate_listings(listings, args.label)

    if args.previous:
        prev_path = Path(args.previous)
        if prev_path.exists():
            with open(prev_path, "r", encoding="utf-8") as f:
                previous = json.load(f)
            consistency = validate_consistency(listings, previous)
            result.errors.extend(consistency.errors)
            result.warnings.extend(consistency.warnings)
            result.stats.update(consistency.stats)

    print(result.report(), file=sys.stderr)

    if args.strict and not result.ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
