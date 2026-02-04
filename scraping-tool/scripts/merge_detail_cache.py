#!/usr/bin/env python3
"""
building_units.json（詳細キャッシュ）の内容を listings JSON にマージする。
SUUMO 物件で、listing の total_units / floor_position / floor_total / floor_structure / ownership が
None または無い場合にのみ、キャッシュの値で上書きする。

使い方:
  python scripts/merge_detail_cache.py results/latest.json
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE_PATH = ROOT / "data" / "building_units.json"
KEYS = ("total_units", "floor_position", "floor_total", "floor_structure", "ownership")


def main() -> None:
    if len(sys.argv) < 2:
        print("usage: merge_detail_cache.py <listings.json>", file=sys.stderr)
        sys.exit(1)
    json_path = Path(sys.argv[1])
    if not json_path.exists():
        print(f"ファイルがありません: {json_path}", file=sys.stderr)
        sys.exit(1)

    with open(json_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        print("JSON は配列である必要があります", file=sys.stderr)
        sys.exit(1)

    if not CACHE_PATH.exists():
        print(f"キャッシュがありません: {CACHE_PATH}", file=sys.stderr)
        sys.exit(0)

    with open(CACHE_PATH, "r", encoding="utf-8") as f:
        cache = json.load(f)

    merged = 0
    for r in listings:
        if not isinstance(r, dict) or r.get("source") != "suumo":
            continue
        url = r.get("url")
        if not url or url not in cache:
            continue
        entry = cache[url]
        if isinstance(entry, int):
            entry = {"total_units": entry}
        for key in KEYS:
            if key not in entry or entry[key] is None:
                continue
            if r.get(key) is None or (key in r and r[key] is None):
                r[key] = entry[key]
                merged += 1

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    print(f"詳細キャッシュをマージしました: {json_path}（{merged}件のフィールドを補完）", file=sys.stderr)


if __name__ == "__main__":
    main()
