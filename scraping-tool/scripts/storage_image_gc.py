#!/usr/bin/env python3
"""listing-images の不要画像を GC（削除）する。

削除対象:
  - 孤児: enrichments のどの行からも参照されていないオブジェクト
  - 掲載終了のみ参照: is_active=false の物件からしか参照されていないオブジェクト

あわせて以下の整合性処理を行う:
  - マニフェスト（data/floor_plan_storage_manifest.json）から削除済み
    オブジェクトのエントリを剪定（再掲載時に再アップロードさせるため）
  - 掲載終了物件の enrichments 行から削除済みストレージ URL の参照を除去

フェイルセーフ（フェイルクローズ原則）:
  - デフォルトは dry-run。--execute 指定時のみ実削除
  - enrichments / listings / オブジェクト一覧のいずれかが空なら中止
  - active 参照が 1 件もない場合は取得失敗とみなして中止
  - 削除比率が --max-delete-ratio を超える場合は中止
  - 直近 --grace-hours 時間以内に作成されたオブジェクトは削除しない
    （アップロード直後で enrichments 未反映の画像を守る）

使い方:
  python3 scripts/storage_image_gc.py                # dry-run
  python3 scripts/storage_image_gc.py --execute      # 実削除
  python3 scripts/storage_image_gc.py --backend r2 --execute
"""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import image_storage  # noqa: E402
from logger import get_logger  # noqa: E402
from storage_gc import collect_refs, prune_manifest, scrub_enrichment_row, select_deletable  # noqa: E402
from supabase_client import fetch_paginated, get_client  # noqa: E402
from upload_floor_plans import MANIFEST_PATH, _load_manifest, _save_manifest  # noqa: E402

logger = get_logger(__name__)


def _scrub_enrichments(client, rows: list[dict], deleted_names: set[str], execute: bool) -> int:
    """削除済みオブジェクトへの参照を enrichments から除去する。"""
    scrubbed = 0
    for row in rows:
        payload = scrub_enrichment_row(row, deleted_names)
        if payload is None:
            continue
        scrubbed += 1
        if not execute:
            continue
        try:
            (client.table("enrichments")
             .update(payload)
             .eq("listing_id", row["listing_id"])
             .execute())
        except Exception as e:
            logger.error("enrichments スクラブ失敗 (listing_id=%s): %s",
                         row.get("listing_id"), e)
    return scrubbed


def main() -> None:
    parser = argparse.ArgumentParser(description="listing-images の不要画像を GC する")
    parser.add_argument("--execute", action="store_true",
                        help="実削除を行う（未指定時は dry-run）")
    parser.add_argument("--backend", choices=["supabase", "r2"], default=None,
                        help="対象バックエンド（デフォルト: R2 設定済みなら r2、なければ supabase）")
    parser.add_argument("--max-delete-ratio", type=float, default=0.6,
                        help="全オブジェクトに対する削除比率の上限（超過時は中止）")
    parser.add_argument("--grace-hours", type=int, default=24,
                        help="この時間以内に作成されたオブジェクトは削除しない")
    args = parser.parse_args()

    client = get_client()
    if client is None:
        logger.error("SUPABASE_URL/SERVICE_ROLE_KEY 未設定のため中止")
        sys.exit(1)

    backend = args.backend or ("r2" if image_storage.r2_configured() else "supabase")
    if backend == "r2" and not image_storage.r2_configured():
        logger.error("R2_* 環境変数が未設定のため中止")
        sys.exit(1)

    # 1. DB から参照情報を取得
    listings = fetch_paginated(client, "listings", "id, is_active")
    enrichments = fetch_paginated(
        client, "enrichments",
        "listing_id, suumo_images, floor_plan_images, best_thumbnail_url",
    )
    if not listings or not enrichments:
        logger.error("listings/enrichments の取得が空。フェイルクローズで中止 "
                     "(listings=%d, enrichments=%d)", len(listings), len(enrichments))
        sys.exit(1)

    active_ids = {row["id"] for row in listings if row.get("is_active")}
    active_refs, all_refs = collect_refs(enrichments, active_ids)
    if not active_refs:
        logger.error("active 物件からの参照が 0 件。取得失敗とみなして中止")
        sys.exit(1)

    # 2. ストレージのオブジェクト一覧
    if backend == "r2":
        objects = image_storage.list_r2_objects()
    else:
        objects = image_storage.list_supabase_objects(client)
    if not objects:
        logger.error("ストレージのオブジェクト一覧が空。中止")
        sys.exit(1)

    # 3. 削除対象の決定
    deletable = select_deletable(set(objects), active_refs)

    cutoff = datetime.now(timezone.utc) - timedelta(hours=args.grace_hours)
    recent_protected = {
        name for name in deletable
        if (ts := objects[name].get("ts")) is not None and ts > cutoff
    }
    deletable -= recent_protected

    orphans = deletable - all_refs
    inactive_only = deletable & all_refs

    logger.info("[%s] 全%d件 / active参照%d件 / 削除対象%d件 "
                "(孤児%d, 掲載終了のみ%d, 直近作成のため保護%d)",
                backend, len(objects), len(active_refs), len(deletable),
                len(orphans), len(inactive_only), len(recent_protected))

    if not deletable:
        logger.info("削除対象なし。終了")
        return

    ratio = len(deletable) / len(objects)
    if ratio > args.max_delete_ratio:
        logger.error("削除比率 %.1f%% が上限 %.1f%% を超過。フェイルクローズで中止",
                     ratio * 100, args.max_delete_ratio * 100)
        sys.exit(1)

    # 4. マニフェスト剪定 → enrichments スクラブ → ストレージ削除 の順
    #    （途中失敗しても残骸が孤児として次回 GC されるだけで済む順序）
    manifest = _load_manifest()
    pruned_manifest, pruned_count = prune_manifest(manifest, deletable)

    if not args.execute:
        scrub_count = _scrub_enrichments(client, enrichments, deletable, execute=False)
        logger.info("[dry-run] 削除%d件 / マニフェスト剪定%d件 / "
                    "enrichments スクラブ%d行（--execute で実行）",
                    len(deletable), pruned_count, scrub_count)
        return

    if pruned_count:
        _save_manifest(pruned_manifest)
        logger.info("マニフェスト剪定: %d件 (%s)", pruned_count, MANIFEST_PATH)

    scrub_count = _scrub_enrichments(client, enrichments, deletable, execute=True)
    logger.info("enrichments スクラブ: %d行", scrub_count)

    names = sorted(deletable)
    if backend == "r2":
        deleted = image_storage.delete_r2_objects(names)
    else:
        deleted = image_storage.delete_supabase_objects(client, names)
    logger.info("ストレージ削除完了: %d/%d件", deleted, len(names))

    if deleted < len(names):
        sys.exit(1)


if __name__ == "__main__":
    main()
