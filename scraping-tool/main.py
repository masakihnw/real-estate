#!/usr/bin/env python3
"""
SUUMO / HOME'S / アットホーム / リハウス / ノムコム / 住友不動産販売 / 東急リバブル
から10年住み替え前提の中古・新築マンション条件に合う候補をスクレイピングし、
CSV/JSON で出力する。

※ HOME'S は WAF が厳しく実用的な取得が困難なため、現在は無効化。
  --source homes / both オプションは残っているが、定期実行では使用しない。

利用規約: terms-check.md を参照。私的利用・軽負荷を前提とする。

  python main.py                                  # 中古 SUUMO のみ（デフォルト）
  python main.py --source all                     # 全ソースから中古取得
  python main.py --property-type shinchiku        # 新築 SUUMO のみ
  python main.py --max-pages 2 --no-filter        # フィルタなしで2ページ取得
  python main.py --output result.json
"""

import argparse
import csv
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# スクリプト配置が scraping-tool/ である前提
sys.path.insert(0, str(Path(__file__).resolve().parent))

from logger import get_logger
logger = get_logger(__name__)

# Firestore からスクレイピング条件を取得（config を使用する全モジュールの import より前に実行）
try:
    from firestore_config_loader import load_config_from_firestore
    load_config_from_firestore()
except Exception as e:
    logger.warning("Firestore 設定の読み込みに失敗（デフォルトを使用）: %s", e)

from report_utils import listing_key, clean_listing_name, fuzzy_identity_match, building_key


def _collect_sources(group: list[dict]) -> list[str]:
    """グループ内の全ソースを重複なしで収集する。"""
    sources = []
    seen = set()
    for r in group:
        s = r.get("source", "unknown")
        if s not in seen:
            sources.append(s)
            seen.add(s)
    return sources


def dedupe_listings(rows: list[dict]) -> list[dict]:
    """物件名・間取り・価格が同一の物件を1件にまとめる。
    同一条件が複数ある場合は duplicate_count に戸数を記録し、
    代表以外の URL を alt_urls に保持する。
    クロスサイト重複はファジーマッチングで2次判定する。"""
    from collections import OrderedDict

    # 1次判定: listing_key 完全一致
    groups: OrderedDict[tuple, list[dict]] = OrderedDict()
    for r in rows:
        key = listing_key(r)
        groups.setdefault(key, []).append(r)

    out: list[dict] = []
    for _key, group in groups.items():
        representative = max(group, key=lambda r: sum(1 for v in r.values() if v is not None))
        count = len(group)
        representative["duplicate_count"] = count
        if count > 1:
            alts = [(r.get("source", "unknown"), r["url"])
                    for r in group if r.get("url") and r["url"] != representative.get("url")]
            if alts:
                representative["alt_sources"] = [s for s, _ in alts]
                representative["alt_urls"] = [u for _, u in alts]
        out.append(representative)

    # 2次判定: ファジーマッチング（クロスサイト表記揺れの吸収）
    merged = []
    used = set()
    for i, a in enumerate(out):
        if i in used:
            continue
        group = [a]
        for j in range(i + 1, len(out)):
            if j in used:
                continue
            if a.get("source") == out[j].get("source"):
                continue
            if fuzzy_identity_match(a, out[j]):
                group.append(out[j])
                used.add(j)
        if len(group) > 1:
            representative = max(group, key=lambda r: sum(1 for v in r.values() if v is not None))
            alts = [(r.get("source", "unknown"), r["url"])
                    for r in group if r.get("url") and r["url"] != representative.get("url")]
            if alts:
                existing_alt_s = representative.get("alt_sources", [])
                existing_alt_u = representative.get("alt_urls", [])
                representative["alt_sources"] = existing_alt_s + [s for s, _ in alts]
                representative["alt_urls"] = existing_alt_u + [u for _, u in alts]
            representative["duplicate_count"] = representative.get("duplicate_count", 1) + len(group) - 1
            merged.append(representative)
        else:
            merged.append(a)
        used.add(i)

    # 3次判定: 同一建物内で面積・階・価格が一致する物件をマージ
    building_groups: dict[tuple, list[int]] = {}
    for i, r in enumerate(merged):
        bk = building_key(r)
        building_groups.setdefault(bk, []).append(i)

    final = []
    used3: set[int] = set()
    for bk, indices in building_groups.items():
        if len(indices) < 2:
            for idx in indices:
                if idx not in used3:
                    final.append(merged[idx])
                    used3.add(idx)
            continue
        sub: dict[tuple, list[int]] = {}
        for idx in indices:
            r = merged[idx]
            sk = (r.get("area_m2"), r.get("floor_position"), r.get("price_man"))
            if sk == (None, None, None):
                if idx not in used3:
                    final.append(merged[idx])
                    used3.add(idx)
                continue
            sub.setdefault(sk, []).append(idx)
        for sk, sub_indices in sub.items():
            if sub_indices[0] in used3:
                continue
            representative = max(
                (merged[idx] for idx in sub_indices),
                key=lambda r: sum(1 for v in r.values() if v is not None),
            )
            for idx in sub_indices:
                if merged[idx].get("url") != representative.get("url"):
                    representative.setdefault("alt_sources", []).append(merged[idx].get("source", "unknown"))
                    representative.setdefault("alt_urls", []).append(merged[idx]["url"])
            representative["duplicate_count"] = sum(merged[idx].get("duplicate_count", 1) for idx in sub_indices)
            final.append(representative)
            for idx in sub_indices:
                used3.add(idx)
        for idx in indices:
            if idx not in used3:
                final.append(merged[idx])
                used3.add(idx)

    return final


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


def _scrape_athome_chuko(max_pages: int, apply_filter: bool) -> list[dict]:
    """アットホーム中古スクレイピング（スレッド用）"""
    from athome_scraper import scrape_athome, enrich_athome_listings
    listings = list(scrape_athome(max_pages=max_pages, apply_filter=apply_filter))
    listings = enrich_athome_listings(listings)
    rows = []
    for row in listings:
        d = row.to_dict()
        d["property_type"] = "chuko"
        rows.append(d)
    return rows


def _scrape_rehouse_chuko(max_pages: int, apply_filter: bool) -> list[dict]:
    """リハウス中古スクレイピング（スレッド用）"""
    from rehouse_scraper import scrape_rehouse, enrich_rehouse_listings
    listings = list(scrape_rehouse(max_pages=max_pages, apply_filter=apply_filter))
    listings = enrich_rehouse_listings(listings)
    rows = []
    for row in listings:
        d = row.to_dict()
        d["property_type"] = "chuko"
        rows.append(d)
    return rows


def _scrape_nomucom_chuko(max_pages: int, apply_filter: bool) -> list[dict]:
    """ノムコム中古スクレイピング（スレッド用）"""
    from nomucom_scraper import scrape_nomucom, enrich_nomucom_listings
    listings = list(scrape_nomucom(max_pages=max_pages, apply_filter=apply_filter))
    listings = enrich_nomucom_listings(listings)
    rows = []
    for row in listings:
        d = row.to_dict()
        d["property_type"] = "chuko"
        rows.append(d)
    return rows


def _scrape_stepon_chuko(max_pages: int, apply_filter: bool) -> list[dict]:
    """住友不動産販売中古スクレイピング（スレッド用）"""
    from stepon_scraper import scrape_stepon, enrich_stepon_listings
    listings = list(scrape_stepon(max_pages=max_pages, apply_filter=apply_filter))
    listings = enrich_stepon_listings(listings)
    rows = []
    for row in listings:
        d = row.to_dict()
        d["property_type"] = "chuko"
        rows.append(d)
    return rows


def _scrape_livable_chuko(max_pages: int, apply_filter: bool) -> list[dict]:
    """東急リバブル中古スクレイピング（スレッド用）"""
    from livable_scraper import scrape_livable, enrich_livable_listings
    listings = list(scrape_livable(max_pages=max_pages, apply_filter=apply_filter))
    listings = enrich_livable_listings(listings)
    rows = []
    for row in listings:
        d = row.to_dict()
        d["property_type"] = "chuko"
        rows.append(d)
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description="マンション条件に合う物件を SUUMO/HOME'S から取得（中古・新築対応）")
    ap.add_argument("--source", choices=["suumo", "homes", "athome", "rehouse", "nomucom", "stepon", "livable", "all", "both"], default="suumo", help="取得元")
    ap.add_argument("--property-type", choices=["chuko", "shinchiku"], default="chuko", help="物件種別（中古 or 新築）")
    ap.add_argument("--max-pages", type=int, default=0, help="最大ページ数。0=結果がなくなるまで全ページ取得（デフォルト）")
    ap.add_argument("--no-filter", action="store_true", help="条件フィルタをかけずに全件出力")
    ap.add_argument("--output", "-o", default="", help="出力ファイル（.csv / .json）。未指定なら stdout に JSON")
    args = ap.parse_args()

    all_rows: list[dict] = []

    # property_type に応じたスクレイパー関数を選択
    scraper_map = {
        "chuko": {
            "suumo": _scrape_suumo_chuko,
            "homes": _scrape_homes_chuko,
            "athome": _scrape_athome_chuko,
            "rehouse": _scrape_rehouse_chuko,
            "nomucom": _scrape_nomucom_chuko,
            "stepon": _scrape_stepon_chuko,
            "livable": _scrape_livable_chuko,
        },
        "shinchiku": {"suumo": _scrape_suumo_shinchiku, "homes": _scrape_homes_shinchiku},
    }
    scrapers = scraper_map[args.property_type]
    type_label = "中古" if args.property_type == "chuko" else "新築"

    # ソース選択: all は全ソース、both は suumo+homes（後方互換）、単一指定も可
    if args.source == "all":
        sources_to_run = list(scrapers.keys())
    elif args.source == "both":
        sources_to_run = ["suumo", "homes"]
    else:
        sources_to_run = [args.source]

    tasks = {}
    with ThreadPoolExecutor(max_workers=7) as executor:
        for src in sources_to_run:
            if src in scrapers:
                tasks[src] = executor.submit(scrapers[src], args.max_pages, not args.no_filter)
        for name, future in tasks.items():
            try:
                all_rows.extend(future.result())
            except Exception as e:
                logger.error("%s %s取得エラー: %s", name, type_label, e)

    # 物件名のノイズ除去（「新築マンション」prefix、「閲覧済」suffix、「掲載物件X件」、
    # 「ペット可」等の条件タグ）
    for row in all_rows:
        if row.get("name"):
            cleaned = clean_listing_name(row["name"])
            row["name"] = cleaned if cleaned else "（不明）"

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
            logger.info("Wrote %d rows to %s", len(all_rows), outpath)
        else:
            with open(outpath, "w", encoding="utf-8") as f:
                json.dump(all_rows, f, ensure_ascii=False, indent=2)
            logger.info("Wrote %d rows to %s", len(all_rows), outpath)
    else:
        print(json.dumps(all_rows, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
