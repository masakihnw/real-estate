#!/usr/bin/env python3
"""
REINS以外の物件サイト（SUUMO / HOME'S）から、10年住み替え前提の中古マンション条件に
合う候補をスクレイピングし、CSV/JSON で出力する。

利用規約: terms-check.md を参照。私的利用・軽負荷を前提とする。
  python main.py              # SUUMO のみ、1ページ、条件フィルタあり
  python main.py --max-pages 2 --no-filter  # フィルタなしで2ページ取得
  python main.py --output result.json
"""

import argparse
import csv
import json
import sys
from pathlib import Path

# スクリプト配置が scraping-tool/ である前提
sys.path.insert(0, str(Path(__file__).resolve().parent))

from suumo_scraper import scrape_suumo

try:
    from generate_report import listing_key
except ImportError:
    def listing_key(r: dict) -> tuple:
        return (
            (r.get("name") or "").strip(),
            (r.get("layout") or "").strip(),
            r.get("area_m2"), r.get("price_man"),
            (r.get("address") or "").strip(), r.get("built_year"),
            (r.get("station_line") or "").strip(), r.get("walk_min"),
        )


def dedupe_listings(rows: list[dict]) -> list[dict]:
    """同じ名前かつ条件（間取り・広さ・価格・住所・築年・駅徒歩）が全て一致する物件を1件にまとめる。"""
    seen: set[tuple] = set()
    out: list[dict] = []
    for r in rows:
        key = listing_key(r)
        if key in seen:
            continue
        seen.add(key)
        out.append(r)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="中古マンション条件に合う物件を SUUMO/HOME'S から取得（REINS除く）")
    ap.add_argument("--source", choices=["suumo", "homes", "both"], default="suumo", help="取得元")
    ap.add_argument("--max-pages", type=int, default=0, help="最大ページ数。0=結果がなくなるまで全ページ取得（デフォルト）")
    ap.add_argument("--no-filter", action="store_true", help="条件フィルタをかけずに全件出力")
    ap.add_argument("--output", "-o", default="", help="出力ファイル（.csv / .json）。未指定なら stdout に JSON")
    args = ap.parse_args()

    all_rows: list[dict] = []
    if args.source in ("suumo", "both"):
        for row in scrape_suumo(max_pages=args.max_pages, apply_filter=not args.no_filter):
            all_rows.append(row.to_dict())
    if args.source in ("homes", "both"):
        try:
            from homes_scraper import scrape_homes
            for row in scrape_homes(max_pages=args.max_pages, apply_filter=not args.no_filter):
                all_rows.append(row.to_dict())
        except Exception as e:
            print(f"# HOME'S 取得は未実装またはエラー: {e}", file=sys.stderr)

    # 同一物件（名前・間取り・広さ・価格・住所・築年・駅徒歩が全て一致）を1件にまとめる
    all_rows = dedupe_listings(all_rows)

    if args.output:
        outpath = Path(args.output)
        outpath.parent.mkdir(parents=True, exist_ok=True)
        if outpath.suffix.lower() == ".csv" and all_rows:
            keys = list(all_rows[0].keys())
            with open(outpath, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
                w.writeheader()
                w.writerows(all_rows)
            print(f"Wrote {len(all_rows)} rows to {outpath}", file=sys.stderr)
        else:
            with open(outpath, "w", encoding="utf-8") as f:
                json.dump(all_rows, f, ensure_ascii=False, indent=2)
            print(f"Wrote {len(all_rows)} rows to {outpath}", file=sys.stderr)
    else:
        print(json.dumps(all_rows, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
