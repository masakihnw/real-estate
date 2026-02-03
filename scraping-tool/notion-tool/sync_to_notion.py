#!/usr/bin/env python3
"""
スクレイピング結果（JSON）を Notion のデータベースに同期する。
- 表のカラムはそのまま DB のプロパティとして保存
- 各ページの詳細に、SUUMO/HOME'S の物件ページを Web Clipper 風に保存（ブックマーク + HTML 全文）
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
    append_blocks,
    create_page,
    get_database_select_options,
    listing_to_properties,
    make_bookmark_block,
    make_code_blocks,
    make_heading2_block,
    make_image_block,
    query_database_by_url,
    update_page_properties,
)

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


def build_page_children(detail_url: str, html: str) -> list[dict]:
    """
    Notion ページの子ブロックを組み立てる。
    ブックマーク ＋ ページ内画像 ＋ 「保存時点の HTML」見出し＋コードブロック群。
    """
    children = []
    if detail_url:
        children.append(make_bookmark_block(detail_url))
    # ページ内画像を保存
    if html and detail_url:
        image_urls = extract_image_urls(html, detail_url)
        if image_urls:
            children.append(make_heading2_block("ページ内画像"))
            for img_url in image_urls:
                children.append(make_image_block(img_url))
    children.append(make_heading2_block("ページ HTML（保存時点）"))
    if html:
        children.extend(make_code_blocks(html))
    else:
        children.append(
            {
                "object": "block",
                "type": "paragraph",
                "paragraph": {"rich_text": [{"text": {"content": "（取得できませんでした）"}}]},
            }
        )
    return children


def main() -> None:
    ap = argparse.ArgumentParser(description="物件 JSON を Notion データベースに同期（Web Clipper 風に詳細ページを保存）")
    ap.add_argument("json_path", type=Path, help="物件一覧 JSON（例: results/latest.json）")
    ap.add_argument("--compare", type=Path, default=None, help="前回結果 JSON。指定時は新規＋価格変動のみ同期")
    ap.add_argument("--refresh-html", action="store_true", help="既存ページも HTML を再取得してブロックを追加する（重い）")
    ap.add_argument("--limit", type=int, default=0, help="同期する最大件数。0=無制限")
    ap.add_argument("--dry-run", action="store_true", help="実際には Notion に書き込まない")
    args = ap.parse_args()

    import os
    database_id = (os.environ.get("NOTION_DATABASE_ID") or "").strip()
    if not database_id:
        print("NOTION_DATABASE_ID が設定されていません", file=sys.stderr)
        sys.exit(1)

    # Select は既存の選択肢のみ設定し、新規の選択肢を Notion に作成しない
    try:
        allowed_select_options = get_database_select_options(database_id)
    except Exception as e:
        print(f"データベースの Select 選択肢を取得できませんでした: {e}（Select は既存のみ選択）", file=sys.stderr)
        allowed_select_options = {}

    listings = load_json(args.json_path, missing_ok=True, default=[])
    if not listings:
        print("物件が0件です", file=sys.stderr)
        sys.exit(0)

    removed_listings: list[dict] = []
    if args.compare and args.compare.exists():
        prev = load_json(args.compare, missing_ok=True, default=[])
        diff = compare_listings(listings, prev)
        to_sync = [r for r in diff["new"]]
        for item in diff["updated"]:
            to_sync.append(item["current"])
        removed_listings = diff.get("removed", [])
        listings = to_sync
        print(f"新規 {len(diff['new'])} 件、価格変動 {len(diff['updated'])} 件を同期対象にします", file=sys.stderr)
        if removed_listings:
            print(f"売り切れ（削除）: {len(removed_listings)} 件を Notion で「売り切れ」に更新します", file=sys.stderr)
    else:
        print(f"全 {len(listings)} 件を同期対象にします", file=sys.stderr)

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
                    {"ステータス": {"status": {"name": "売り切れ"}}},
                )
                sold_out_updated += 1
                print(f"  [売り切れ] {(r.get('name') or '')[:36]}", file=sys.stderr)
        except Exception as e:
            errors += 1
            print(f"  [error 売り切れ] {(r.get('name') or '')[:30]}: {e}", file=sys.stderr)
        time.sleep(0.35)
    if removed_listings:
        time.sleep(REQUEST_DELAY_SEC)

    for i, r in enumerate(listings):
        url = (r.get("url") or "").strip()
        if not url:
            print(f"  [skip] URL なし: {(r.get('name') or '')[:30]}", file=sys.stderr)
            continue

        try:
            existing = query_database_by_url(database_id, url)
            props = listing_to_properties(r, sold_out=False, allowed_select_options=allowed_select_options)

            if existing:
                page_id = existing["id"]
                update_page_properties(page_id, props)
                updated += 1
                if args.refresh_html:
                    html = fetch_page_html(url)
                    time.sleep(REQUEST_DELAY_SEC)
                    children = build_page_children(url, html)
                    append_blocks(page_id, children)
                print(f"  [update] {(r.get('name') or '')[:36]}", file=sys.stderr)
            else:
                html = fetch_page_html(url)
                time.sleep(REQUEST_DELAY_SEC)
                children = build_page_children(url, html)
                create_page(database_id, props, children=children)
                created += 1
                print(f"  [create] {(r.get('name') or '')[:36]}", file=sys.stderr)
        except Exception as e:
            errors += 1
            print(f"  [error] {(r.get('name') or '')[:30]}: {e}", file=sys.stderr)

        if (i + 1) < len(listings):
            time.sleep(REQUEST_DELAY_SEC)

    print(f"完了: 新規 {created}、更新 {updated}、売り切れ {sold_out_updated}、エラー {errors}", file=sys.stderr)
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
