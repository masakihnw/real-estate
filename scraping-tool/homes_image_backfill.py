#!/usr/bin/env python3
"""HOME'S 物件の画像バックフィル。

DB上の homes 物件で suumo_images が未登録のものを対象に、
詳細ページから画像を取得して enrichments テーブルに直接書き込む。

Claude セッション不要のスタンドアロンスクリプト。
深夜に nohup で実行することを想定。

使い方:
  # 全件（デフォルト5秒間隔）
  nohup python3 homes_image_backfill.py 2>&1 | tee logs/backfill.log &

  # 件数制限+間隔指定
  python3 homes_image_backfill.py --limit 50 --delay 8

  # ドライラン（DB書き込みなし）
  python3 homes_image_backfill.py --dry-run --limit 5
"""

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from floor_plan_enricher import (
    fetch_homes_detail,
    parse_homes_floor_plan_images,
    parse_homes_property_images,
    _read_cached_html,
    _write_html_cache,
    _load_manifest,
)
from scraper_common import create_session
from supabase_client import get_client
from logger import get_logger

logger = get_logger(__name__)

BATCH_SIZE = 50


def _fetch_targets(client, limit: int) -> list[dict]:
    """DB から homes 画像なし物件を取得する。"""
    query = (
        client.rpc("get_homes_no_images", {})
    )
    try:
        resp = query.execute()
        if resp.data:
            rows = resp.data
            if limit > 0:
                rows = rows[:limit]
            return rows
    except Exception:
        pass

    # RPC がない場合はフォールバック（新着優先で取得）
    all_rows = []
    offset = 0
    page_size = 500
    while True:
        resp = (
            client.table("listing_facts")
            .select("id, sources_json, first_seen_at")
            .eq("status", "active")
            .is_("suumo_images", "null")
            .order("first_seen_at", desc=True)
            .range(offset, offset + page_size - 1)
            .execute()
        )
        if not resp.data:
            break
        all_rows.extend(resp.data)
        if len(resp.data) < page_size:
            break
        offset += page_size

    targets = []
    for row in all_rows:
        sources = row.get("sources_json") or []
        homes_url = None
        for s in sources:
            if s.get("source") == "homes" and s.get("is_active"):
                homes_url = s.get("url")
                break
        if homes_url:
            targets.append({"id": row["id"], "url": homes_url})

    if limit > 0:
        targets = targets[:limit]
    return targets


def _upsert_images(client, listing_id: int, suumo_images: list, floor_plan_images: list, dry_run: bool) -> bool:
    """enrichments テーブルに画像を upsert する。"""
    row = {"listing_id": listing_id}
    if suumo_images:
        row["suumo_images"] = suumo_images
    if floor_plan_images:
        row["floor_plan_images"] = floor_plan_images

    if len(row) <= 1:
        return False

    if dry_run:
        logger.info(f"  [DRY-RUN] upsert listing_id={listing_id}: "
                     f"suumo={len(suumo_images or [])}枚, fp={len(floor_plan_images or [])}枚")
        return True

    try:
        client.table("enrichments").upsert(
            row, on_conflict="listing_id", returning="minimal"
        ).execute()
        return True
    except Exception as e:
        logger.error(f"  DB書き込み失敗 listing_id={listing_id}: {e}")
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description="HOME'S 画像バックフィル（DB直接）")
    parser.add_argument("--limit", type=int, default=0, help="処理上限（0=全件）")
    parser.add_argument("--delay", type=float, default=5.0, help="リクエスト間隔（秒）")
    parser.add_argument("--dry-run", action="store_true", help="DB書き込みなし")
    args = parser.parse_args()

    client = get_client()
    if client is None:
        logger.error("Supabase 未設定。SUPABASE_SERVICE_ROLE_KEY を設定してください。")
        sys.exit(1)

    logger.info("DB から対象物件を取得中...")
    targets = _fetch_targets(client, args.limit)
    logger.info(f"対象: {len(targets)}件")

    if not targets:
        logger.info("バックフィル対象なし")
        return

    session = create_session()
    manifest = _load_manifest()
    stats = {"success": 0, "cached": 0, "waf_fail": 0, "error": 0, "no_images": 0}
    consecutive_waf = 0
    start_time = time.monotonic()

    for idx, target in enumerate(targets):
        if consecutive_waf >= 5:
            logger.warning(f"WAF 連続{consecutive_waf}回: 残り{len(targets) - idx}件を中断")
            break

        listing_id = target["id"]
        url = target["url"]
        logger.info(f"[{idx + 1}/{len(targets)}] id={listing_id} {url}")

        html = _read_cached_html(url, manifest)
        if html is not None:
            stats["cached"] += 1
            consecutive_waf = 0
        else:
            time.sleep(args.delay)
            try:
                html = fetch_homes_detail(session, url)
                _write_html_cache(url, html, manifest)
                consecutive_waf = 0
            except Exception as e:
                logger.error(f"  取得失敗: {e}")
                consecutive_waf += 1
                stats["waf_fail"] += 1
                continue

        prop_images = parse_homes_property_images(html)
        fp_images = parse_homes_floor_plan_images(html)

        if not prop_images and not fp_images:
            logger.info(f"  画像なし（ページに画像要素がない）")
            stats["no_images"] += 1
            continue

        ok = _upsert_images(client, listing_id, prop_images, fp_images, args.dry_run)
        if ok:
            stats["success"] += 1
            logger.info(f"  ✓ 写真{len(prop_images)}枚, 間取り{len(fp_images)}枚")
        else:
            stats["error"] += 1

        if (idx + 1) % 20 == 0:
            elapsed = int(time.monotonic() - start_time)
            logger.info(f"  === 進捗: {idx + 1}/{len(targets)}件, {elapsed}秒経過 ===")

    elapsed = int(time.monotonic() - start_time)
    logger.info(
        f"\n=== バックフィル完了 ===\n"
        f"  成功: {stats['success']}件\n"
        f"  キャッシュ利用: {stats['cached']}件\n"
        f"  WAF失敗: {stats['waf_fail']}件\n"
        f"  画像なし: {stats['no_images']}件\n"
        f"  DB書き込みエラー: {stats['error']}件\n"
        f"  所要時間: {elapsed}秒"
    )


if __name__ == "__main__":
    main()
