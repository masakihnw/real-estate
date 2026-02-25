#!/usr/bin/env python3
"""
供給トレンドデータを生成する。
latest.json と previous.json の差分から新着・掲載終了の推移を蓄積し、
supply_trends.json として出力する。iOS アプリのダッシュボード画面で使用。
"""

import json
import sys
from collections import Counter
from datetime import date
from pathlib import Path
from typing import Any

try:
    from report_utils import (
        compare_listings,
        get_ward_from_address,
        identity_key,
        load_json,
    )
except ImportError:
    sys.path.insert(0, str(Path(__file__).parent))
    from report_utils import (
        compare_listings,
        get_ward_from_address,
        identity_key,
        load_json,
    )


def build_supply_snapshot(
    current: list[dict],
    previous: list[dict],
    today: str,
) -> dict[str, Any]:
    """1回分のスナップショットを生成する。"""
    diff = compare_listings(current, previous)

    ward_counts: Counter = Counter()
    ward_avg_price: dict[str, list[int]] = {}
    for r in current:
        ward = get_ward_from_address(r.get("address") or "")
        if ward:
            ward_counts[ward] += 1
            price = r.get("price_man")
            if price:
                ward_avg_price.setdefault(ward, []).append(price)

    ward_stats = {}
    for ward, count in ward_counts.most_common():
        prices = ward_avg_price.get(ward, [])
        ward_stats[ward] = {
            "count": count,
            "avg_price_man": int(sum(prices) / len(prices)) if prices else None,
            "min_price_man": min(prices) if prices else None,
            "max_price_man": max(prices) if prices else None,
        }

    price_dist = {"under_10000": 0, "10000_11000": 0, "11000_12000": 0, "over_12000": 0, "undecided": 0}
    for r in current:
        price = r.get("price_man")
        if price is None:
            price_dist["undecided"] += 1
        elif price < 10000:
            price_dist["under_10000"] += 1
        elif price < 11000:
            price_dist["10000_11000"] += 1
        elif price <= 12000:
            price_dist["11000_12000"] += 1
        else:
            price_dist["over_12000"] += 1

    all_prices = [r["price_man"] for r in current if r.get("price_man")]

    return {
        "date": today,
        "total_listings": len(current),
        "new_count": len(diff["new"]),
        "removed_count": len(diff["removed"]),
        "updated_count": len(diff["updated"]),
        "price_changed_count": sum(
            1 for item in diff["updated"]
            if item["current"].get("price_man") != item["previous"].get("price_man")
        ),
        "avg_price_man": int(sum(all_prices) / len(all_prices)) if all_prices else None,
        "median_price_man": sorted(all_prices)[len(all_prices) // 2] if all_prices else None,
        "price_distribution": price_dist,
        "ward_stats": ward_stats,
    }


def main():
    import argparse
    parser = argparse.ArgumentParser(description="供給トレンドデータ生成")
    parser.add_argument("--current", required=True, help="現在の物件 JSON")
    parser.add_argument("--previous", help="前回の物件 JSON")
    parser.add_argument("--current-shinchiku", help="現在の新築 JSON")
    parser.add_argument("--previous-shinchiku", help="前回の新築 JSON")
    parser.add_argument("--output", default="results/supply_trends.json", help="出力先")
    parser.add_argument("--max-history", type=int, default=365, help="保持する最大日数")
    args = parser.parse_args()

    today = date.today().isoformat()
    output_path = Path(args.output)

    existing: dict[str, Any] = {"chuko": [], "shinchiku": [], "metadata": {}}
    if output_path.exists():
        with open(output_path, "r", encoding="utf-8") as f:
            existing = json.load(f)

    current = load_json(Path(args.current))
    previous = load_json(Path(args.previous), missing_ok=True, default=[]) if args.previous else []

    chuko_snapshot = build_supply_snapshot(current, previous, today)
    chuko_history: list = existing.get("chuko", [])
    if chuko_history and chuko_history[-1].get("date") == today:
        chuko_history[-1] = chuko_snapshot
    else:
        chuko_history.append(chuko_snapshot)
    chuko_history = chuko_history[-args.max_history:]

    shinchiku_history: list = existing.get("shinchiku", [])
    if args.current_shinchiku:
        cur_s = load_json(Path(args.current_shinchiku), missing_ok=True, default=[])
        prev_s = load_json(Path(args.previous_shinchiku), missing_ok=True, default=[]) if args.previous_shinchiku else []
        if cur_s:
            shinchiku_snapshot = build_supply_snapshot(cur_s, prev_s, today)
            if shinchiku_history and shinchiku_history[-1].get("date") == today:
                shinchiku_history[-1] = shinchiku_snapshot
            else:
                shinchiku_history.append(shinchiku_snapshot)
            shinchiku_history = shinchiku_history[-args.max_history:]

    result = {
        "chuko": chuko_history,
        "shinchiku": shinchiku_history,
        "metadata": {
            "last_updated": today,
            "total_snapshots_chuko": len(chuko_history),
            "total_snapshots_shinchiku": len(shinchiku_history),
        },
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(f"供給トレンド更新完了: 中古 {len(chuko_history)}日分, 新築 {len(shinchiku_history)}日分", file=sys.stderr)


if __name__ == "__main__":
    main()
