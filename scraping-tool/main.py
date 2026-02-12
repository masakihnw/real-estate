#!/usr/bin/env python3
"""
REINS以外の物件サイト（SUUMO / HOME'S）から、10年住み替え前提の中古マンション条件に
合う候補をスクレイピングし、CSV/JSON で出力する。新築マンションにも対応。

利用規約: terms-check.md を参照。私的利用・軽負荷を前提とする。

  python main.py                                  # 中古 SUUMO のみ
  python main.py --source both                    # 中古 SUUMO + HOME'S
  python main.py --property-type shinchiku        # 新築 SUUMO のみ
  python main.py --property-type shinchiku --source both  # 新築 SUUMO + HOME'S
  python main.py --max-pages 2 --no-filter        # フィルタなしで2ページ取得
  python main.py --output result.json
"""

import argparse
import csv
import json
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# スクリプト配置が scraping-tool/ である前提
sys.path.insert(0, str(Path(__file__).resolve().parent))

# Firestore からスクレイピング条件を取得（config を使用する全モジュールの import より前に実行）
try:
    from firestore_config_loader import load_config_from_firestore
    load_config_from_firestore()
except Exception as e:
    print(f"[Config] Firestore 設定の読み込みに失敗（デフォルトを使用）: {e}", file=sys.stderr)

from report_utils import listing_key, clean_listing_name


def dedupe_listings(rows: list[dict]) -> list[dict]:
    """物件名・間取り・価格が同一の物件を1件にまとめる。
    同一条件が複数ある場合は duplicate_count に戸数を記録し、
    代表以外の URL を alt_urls に保持する。"""
    from collections import OrderedDict

    groups: OrderedDict[tuple, list[dict]] = OrderedDict()
    for r in rows:
        key = listing_key(r)
        groups.setdefault(key, []).append(r)

    out: list[dict] = []
    for _key, group in groups.items():
        # 代表行: 情報量が多い（None でないフィールドが多い）ものを選ぶ
        representative = max(group, key=lambda r: sum(1 for v in r.values() if v is not None))
        count = len(group)
        representative["duplicate_count"] = count
        if count > 1:
            # 代表以外の URL を alt_urls に保持（情報を失わない）
            alt = [r["url"] for r in group if r.get("url") and r["url"] != representative.get("url")]
            if alt:
                representative["alt_urls"] = alt
        out.append(representative)
    return out


def _scrape_suumo_chuko(max_pages: int, apply_filter: bool) -> list[dict]:
    """SUUMO 中古スクレイピング（スレッド用）"""
    from suumo_scraper import scrape_suumo
    rows = []
    for row in scrape_suumo(max_pages=max_pages, apply_filter=apply_filter):
        d = row.to_dict()
        d["property_type"] = "chuko"
        rows.append(d)
    return rows


def _scrape_homes_chuko(max_pages: int, apply_filter: bool) -> list[dict]:
    """HOME'S 中古スクレイピング（スレッド用）"""
    from homes_scraper import scrape_homes
    rows = []
    for row in scrape_homes(max_pages=max_pages, apply_filter=apply_filter):
        d = row.to_dict()
        d["property_type"] = "chuko"
        rows.append(d)
    return rows


def _scrape_suumo_shinchiku(max_pages: int, apply_filter: bool) -> list[dict]:
    """SUUMO 新築スクレイピング（スレッド用）"""
    from suumo_shinchiku_scraper import scrape_suumo_shinchiku
    rows = []
    for row in scrape_suumo_shinchiku(max_pages=max_pages, apply_filter=apply_filter):
        rows.append(row.to_dict())
    return rows


def _scrape_homes_shinchiku(max_pages: int, apply_filter: bool) -> list[dict]:
    """HOME'S 新築スクレイピング（スレッド用）"""
    from homes_shinchiku_scraper import scrape_homes_shinchiku
    rows = []
    for row in scrape_homes_shinchiku(max_pages=max_pages, apply_filter=apply_filter):
        rows.append(row.to_dict())
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description="マンション条件に合う物件を SUUMO/HOME'S から取得（中古・新築対応）")
    ap.add_argument("--source", choices=["suumo", "homes", "both"], default="suumo", help="取得元")
    ap.add_argument("--property-type", choices=["chuko", "shinchiku"], default="chuko", help="物件種別（中古 or 新築）")
    ap.add_argument("--max-pages", type=int, default=0, help="最大ページ数。0=結果がなくなるまで全ページ取得（デフォルト）")
    ap.add_argument("--no-filter", action="store_true", help="条件フィルタをかけずに全件出力")
    ap.add_argument("--output", "-o", default="", help="出力ファイル（.csv / .json）。未指定なら stdout に JSON")
    args = ap.parse_args()

    all_rows: list[dict] = []

    # SUUMO と HOME'S を並列スクレイピング（--source both の場合）
    if args.property_type == "chuko":
        tasks = {}
        with ThreadPoolExecutor(max_workers=2) as executor:
            if args.source in ("suumo", "both"):
                tasks["suumo"] = executor.submit(_scrape_suumo_chuko, args.max_pages, not args.no_filter)
            if args.source in ("homes", "both"):
                tasks["homes"] = executor.submit(_scrape_homes_chuko, args.max_pages, not args.no_filter)
            for name, future in tasks.items():
                try:
                    all_rows.extend(future.result())
                except Exception as e:
                    print(f"# {name} 中古取得エラー: {e}", file=sys.stderr)
    else:
        tasks = {}
        with ThreadPoolExecutor(max_workers=2) as executor:
            if args.source in ("suumo", "both"):
                tasks["suumo"] = executor.submit(_scrape_suumo_shinchiku, args.max_pages, not args.no_filter)
            if args.source in ("homes", "both"):
                tasks["homes"] = executor.submit(_scrape_homes_shinchiku, args.max_pages, not args.no_filter)
            for name, future in tasks.items():
                try:
                    all_rows.extend(future.result())
                except Exception as e:
                    print(f"# {name} 新築取得エラー: {e}", file=sys.stderr)

    # 物件名のノイズ除去（「新築マンション」prefix、「閲覧済」suffix、「掲載物件X件」等）
    for row in all_rows:
        if row.get("name"):
            cleaned = clean_listing_name(row["name"])
            if cleaned:
                row["name"] = cleaned

    # 同一物件（名前・間取り・広さ・価格・住所・築年・駅徒歩が全て一致）を1件にまとめる
    all_rows = dedupe_listings(all_rows)

    if args.output:
        outpath = Path(args.output)
        outpath.parent.mkdir(parents=True, exist_ok=True)
        if outpath.suffix.lower() == ".csv":
            keys = list(all_rows[0].keys()) if all_rows else []
            with open(outpath, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
                w.writeheader()
                if all_rows:
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
