#!/usr/bin/env python3
"""
スクレイピング結果（JSON）を Notion のデータベースに同期する。
- 表のカラムはそのまま DB のプロパティとして保存
- 各ページの詳細に、物件詳細 URL を Web Clipper 風に保存（ブックマーク + Embed）。HTML は取得・保存しない。
"""

import argparse
import re
import sys
import time
from pathlib import Path
from urllib.parse import urljoin, urlparse

# 実行時は scraping-tool を cwd に想定
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import requests

from notion_client import (
    NOTION_PAGE_CHILDREN_LIMIT,
    append_blocks,
    create_page,
    listing_to_properties,
    make_bookmark_block,
    make_embed_block,
    query_database_by_url,
    update_page_properties,
)

try:
    from optional_features import optional_features
except ImportError:
    optional_features = None

try:
    from report_utils import compare_listings, load_json
except ImportError:
    def load_json(path, *, missing_ok=False, default=None):
        import json
        if missing_ok and not path.exists():
            return default if default is not None else []
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    def compare_listings(current, previous=None):
        return {"new": current, "updated": [], "removed": []}

try:
    from config import REQUEST_DELAY_SEC, USER_AGENT
except ImportError:
    USER_AGENT = "Mozilla/5.0 (compatible; NotionSync/1.0)"
    REQUEST_DELAY_SEC = 2

# 100件以上あるときのリトライ: 失敗した物件を最大この回数まで再試行
MAX_RETRIES = 3
RETRY_ROUND_DELAY_SEC = 20


def fetch_page_html(url: str) -> str:
    """物件詳細 URL の HTML を取得する。"""
    if not url or not url.strip():
        return ""
    try:
        r = requests.get(
            url.strip(),
            headers={
                "User-Agent": USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "ja,en;q=0.9",
            },
            timeout=30,
        )
        r.raise_for_status()
        return r.text
    except Exception as e:
        return f"<!-- Fetch error: {e} -->"


# ページ内画像を最大何枚まで Notion に保存するか
MAX_PAGE_IMAGES = 30


def extract_image_urls(html: str, base_url: str) -> list[str]:
    """HTML から img の src を抽出し、絶対 URL のリストを返す。"""
    seen: set[str] = set()
    urls: list[str] = []
    # data-src や src を拾う（SUUMO は遅延読み込みで data-src を使うことがある）
    for m in re.finditer(r'<(?:img|IMG)\s[^>]*(?:src|data-src)=["\']([^"\']+)["\']', html):
        raw = m.group(1).strip()
        if not raw or raw.startswith("data:"):
            continue
        abs_url = urljoin(base_url, raw)
        parsed = urlparse(abs_url)
        if parsed.scheme not in ("http", "https"):
            continue
        if abs_url in seen:
            continue
        seen.add(abs_url)
        urls.append(abs_url)
        if len(urls) >= MAX_PAGE_IMAGES:
            break
    return urls


def build_page_children(detail_url: str) -> list[dict]:
    """
    Notion ページの子ブロックを組み立てる（Web Clipper 風）。
    ブックマーク（リンクプレビュー）＋ Embed（URL のウェブページを埋め込み表示）。
    HTML の取得・保存は行わない。
    """
    children = []
    if detail_url:
        children.append(make_bookmark_block(detail_url))
        children.append(make_embed_block(detail_url))
    return children


def sync_one_listing(
    r: dict,
    database_id: str,
    *,
    refresh_html: bool = False,
) -> str:
    """
    1件の物件を Notion に同期する。
    戻り値: "created" | "updated" | "skip"（URL なしでスキップ）。
    例外: 作成・更新に失敗した場合。
    """
    url = (r.get("url") or "").strip()
    if not url:
        return "skip"

    existing = query_database_by_url(database_id, url)
    m3_min, pg_min = (None, None)
    if optional_features:
        m3_min, pg_min = optional_features.get_commute_total_minutes(r.get("station_line"), r.get("walk_min"))
    props = listing_to_properties(r, sold_out=False, m3_min=m3_min, pg_min=pg_min)

    if existing:
        page_id = existing["id"]
        update_page_properties(page_id, props)
        if refresh_html:
            children = build_page_children(url)
            append_blocks(page_id, children)
        return "updated"
    else:
        children = build_page_children(url)
        page = create_page(database_id, props, children=children)
        if len(children) > NOTION_PAGE_CHILDREN_LIMIT:
            append_blocks(page["id"], children[NOTION_PAGE_CHILDREN_LIMIT:])
        return "created"


def main() -> None:
    ap = argparse.ArgumentParser(description="物件 JSON を Notion データベースに同期（Web Clipper 風に詳細ページを保存）")
    ap.add_argument("json_path", type=Path, help="物件一覧 JSON（例: results/latest.json）")
    ap.add_argument("--compare", type=Path, default=None, help="前回結果 JSON。指定時は新規＋価格変動のみ同期")
    ap.add_argument("--refresh-html", action="store_true", help="既存ページにもブックマーク＋Embed ブロックを追加する")
    ap.add_argument("--limit", type=int, default=0, help="同期する最大件数。0=無制限")
    ap.add_argument("--dry-run", action="store_true", help="実際には Notion に書き込まない")
    args = ap.parse_args()

    import os
    database_id = (os.environ.get("NOTION_DATABASE_ID") or "").strip()
    if not database_id:
        print("NOTION_DATABASE_ID が設定されていません", file=sys.stderr)
        sys.exit(1)

    listings = load_json(args.json_path, missing_ok=True, default=[])
    if not listings:
        print("物件が0件です", file=sys.stderr)
        sys.exit(0)

    # 売り切れ判定: --compare で前回結果を渡した場合、今回の一覧から消えた物件を Notion で「売り切れ」に更新
    removed_listings: list[dict] = []
    if args.compare and args.compare.exists():
        prev = load_json(args.compare, missing_ok=True, default=[])
        diff = compare_listings(listings, prev)
        removed_listings = diff.get("removed", [])
        if removed_listings:
            print(f"売り切れ（一覧から削除）: {len(removed_listings)} 件を Notion で「売り切れ」に更新します", file=sys.stderr)

    # 同期対象: latest.json の全件。各件について Notion を URL で検索し、無ければ作成・あれば更新する。
    # → 過去登録済みでも Notion 上で手動削除されていれば「無い」と判定され再登録される。
    print(f"全 {len(listings)} 件を同期対象にします（Notion に無いものは新規作成、あるものは更新）", file=sys.stderr)

    if args.limit > 0:
        listings = listings[: args.limit]
        print(f"件数制限: 先頭 {args.limit} 件のみ", file=sys.stderr)

    if args.dry_run:
        print("（dry-run のため Notion には書き込みません）", file=sys.stderr)
        for r in listings:
            print(f"  - {(r.get('name') or '')[:40]}", file=sys.stderr)
        sys.exit(0)

    created = 0
    updated = 0
    sold_out_updated = 0
    errors = 0

    # レポートから削除された物件 → Notion で「売り切れ」にチェック
    for r in removed_listings:
        url = (r.get("url") or "").strip()
        if not url:
            continue
        try:
            existing = query_database_by_url(database_id, url)
            if existing:
                update_page_properties(
                    existing["id"],
                    {"販売状況": {"status": {"name": "売り切れ"}}},
                )
                sold_out_updated += 1
                print(f"  [売り切れ] {(r.get('name') or '')[:36]}", file=sys.stderr)
        except Exception as e:
            errors += 1
            print(f"  [error 売り切れ] {(r.get('name') or '')[:30]}: {e}", file=sys.stderr)
        time.sleep(0.35)
    if removed_listings:
        time.sleep(REQUEST_DELAY_SEC)

    failed_list: list[dict] = []
    for i, r in enumerate(listings):
        try:
            result = sync_one_listing(r, database_id, refresh_html=args.refresh_html)
            if result == "skip":
                print(f"  [skip] URL なし: {(r.get('name') or '')[:30]}", file=sys.stderr)
                continue
            if result == "created":
                created += 1
                print(f"  [create] {(r.get('name') or '')[:36]}", file=sys.stderr)
            else:
                updated += 1
                print(f"  [update] {(r.get('name') or '')[:36]}", file=sys.stderr)
        except Exception as e:
            errors += 1
            failed_list.append(r)
            print(f"  [error] {(r.get('name') or '')[:30]}: {e}", file=sys.stderr)

        if (i + 1) < len(listings):
            time.sleep(REQUEST_DELAY_SEC)

    # 失敗した物件はスキップして次へ進み、後からリトライ。それでもダメな件だけエラーとして残す
    if failed_list:
        print(f"リトライ: 失敗 {len(failed_list)} 件を最大 {MAX_RETRIES} 回まで再試行します", file=sys.stderr)
        for round_no in range(MAX_RETRIES):
            if not failed_list:
                break
            time.sleep(RETRY_ROUND_DELAY_SEC)
            still_failed: list[dict] = []
            for r in failed_list:
                try:
                    result = sync_one_listing(r, database_id, refresh_html=args.refresh_html)
                    if result == "created":
                        created += 1
                        print(f"  [retry create] {(r.get('name') or '')[:36]}", file=sys.stderr)
                    elif result == "updated":
                        updated += 1
                        print(f"  [retry update] {(r.get('name') or '')[:36]}", file=sys.stderr)
                    else:
                        still_failed.append(r)
                except Exception as e:
                    still_failed.append(r)
                    print(f"  [retry error] {(r.get('name') or '')[:30]}: {e}", file=sys.stderr)
                time.sleep(REQUEST_DELAY_SEC)
            failed_list = still_failed
            if failed_list:
                print(f"  リトライ {round_no + 1}/{MAX_RETRIES} 後、まだ {len(failed_list)} 件失敗", file=sys.stderr)
        errors = len(failed_list)

    print(f"完了: 新規 {created}、更新 {updated}、売り切れ {sold_out_updated}、エラー {errors}", file=sys.stderr)
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
