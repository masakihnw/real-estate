#!/usr/bin/env python3
"""
現在結果と前回結果を比較し、差分があれば exit 0、なければ exit 1 で終了する。
同一物件は名前・間取り・広さ・価格・住所・築年・駅徒歩の一致で判定（URLは見ない）。
update_listings.sh で「変更時のみレポート・通知」するために使用。
"""
import sys
from pathlib import Path

try:
    from generate_report import load_json, listing_key
except ImportError:
    import json
    def load_json(path):
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    def listing_key(r):
        return (
            (r.get("name") or "").strip(),
            (r.get("layout") or "").strip(),
            r.get("area_m2"), r.get("price_man"),
            (r.get("address") or "").strip(), r.get("built_year"),
            (r.get("station_line") or "").strip(), r.get("walk_min"),
        )


def main() -> None:
    if len(sys.argv) != 3:
        print("使い方: python check_changes.py <current.json> <previous.json>", file=sys.stderr)
        sys.exit(2)

    current_path = Path(sys.argv[1])
    previous_path = Path(sys.argv[2])

    if not current_path.exists():
        sys.exit(2)
    if not previous_path.exists():
        sys.exit(0)

    current = load_json(current_path)
    previous = load_json(previous_path)

    curr_by_key = {listing_key(r): r for r in current}
    prev_by_key = {listing_key(r): r for r in previous}

    new = sum(1 for k in curr_by_key if k not in prev_by_key)
    removed = sum(1 for k in prev_by_key if k not in curr_by_key)
    updated = sum(
        1
        for k in curr_by_key
        if k in prev_by_key and curr_by_key[k].get("price_man") != prev_by_key[k].get("price_man")
    )

    has_changes = new > 0 or removed > 0 or updated > 0
    sys.exit(0 if has_changes else 1)


if __name__ == "__main__":
    main()
