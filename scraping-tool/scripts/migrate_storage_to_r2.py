#!/usr/bin/env python3
"""Supabase Storage (listing-images) を Cloudflare R2 へ移行する。

フェーズ:
  copy          全オブジェクトを R2 へコピー（同名・同サイズはスキップ＝中断後の再開可）
  verify        Supabase 側と R2 側の件数・サイズの一致を検証
  rewrite       enrichments / マニフェスト / 指定 JSON ファイル内の URL を R2 に書き換え
  delete-source 検証済みオブジェクトを Supabase Storage から削除（容量解放）

実行順序と安全性:
  copy → verify → rewrite → delete-source の順に実行する。
  rewrite と delete-source は --execute 指定時のみ実変更を行う。
  delete-source は内部で verify を再実行し、R2 に存在しないオブジェクトは削除しない。

使い方:
  python3 scripts/migrate_storage_to_r2.py --phase copy
  python3 scripts/migrate_storage_to_r2.py --phase verify
  python3 scripts/migrate_storage_to_r2.py --phase rewrite \
      --rewrite-file results/latest.json --execute
  python3 scripts/migrate_storage_to_r2.py --phase delete-source --execute
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import threading
from pathlib import Path

import requests

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import image_storage  # noqa: E402
from logger import get_logger  # noqa: E402
from supabase_client import SUPABASE_URL, fetch_paginated, get_client  # noqa: E402
from upload_floor_plans import MANIFEST_PATH, _load_manifest, _save_manifest  # noqa: E402

logger = get_logger(__name__)

MAX_WORKERS = 8
DOWNLOAD_TIMEOUT_SEC = 60
ENRICHMENT_IMAGE_COLUMNS = "listing_id, suumo_images, floor_plan_images, best_thumbnail_url"

_thread_local = threading.local()


def _get_session() -> requests.Session:
    """スレッドローカルな HTTP セッション（コネクション再利用）。"""
    if not hasattr(_thread_local, "session"):
        _thread_local.session = requests.Session()
    return _thread_local.session


def _supabase_public_base() -> str:
    return f"{SUPABASE_URL}/storage/v1/object/public/{image_storage.SUPABASE_BUCKET_NAME}/"


_CONTENT_TYPES = {
    ".jpg": "image/jpeg",
    ".png": "image/png",
    ".gif": "image/gif",
    ".webp": "image/webp",
}


def _copy_one(name: str) -> tuple[str, bool]:
    """Supabase からダウンロードして R2 へアップロード。"""
    url = _supabase_public_base() + name
    try:
        r = _get_session().get(url, timeout=DOWNLOAD_TIMEOUT_SEC)
        r.raise_for_status()
        content_type = _CONTENT_TYPES.get(Path(name).suffix.lower(), "image/jpeg")
        image_storage.upload_image_r2(name, r.content, content_type)
        return name, True
    except Exception as e:
        logger.error("コピー失敗: %s (%s)", name, e)
        return name, False


def phase_copy(client) -> int:
    src = image_storage.list_supabase_objects(client)
    dst = image_storage.list_r2_objects()
    to_copy = [
        name for name, meta in src.items()
        if (dst.get(name) or {}).get("size") != meta["size"]
    ]
    logger.info("コピー対象: %d/%d件（R2 既存スキップ %d件）",
                len(to_copy), len(src), len(src) - len(to_copy))
    if not to_copy:
        return 0

    copied = failed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        for _, ok in executor.map(_copy_one, to_copy):
            if ok:
                copied += 1
            else:
                failed += 1
            if (copied + failed) % 500 == 0:
                logger.info("  ...%d/%d件処理済 (失敗%d)",
                            copied + failed, len(to_copy), failed)
    logger.info("コピー完了: 成功%d / 失敗%d", copied, failed)
    return failed


def phase_verify(client) -> tuple[set[str], dict[str, dict]]:
    """(R2 未到達・サイズ不一致のオブジェクト集合, Supabase 側一覧) を返す。"""
    src = image_storage.list_supabase_objects(client)
    dst = image_storage.list_r2_objects()
    missing = {
        name for name, meta in src.items()
        if (dst.get(name) or {}).get("size") != meta["size"]
    }
    src_bytes = sum(meta["size"] for meta in src.values())
    logger.info("verify: Supabase %d件/%.1fMB, R2 %d件, 未移行/不一致 %d件",
                len(src), src_bytes / 1e6, len(dst), len(missing))
    for name in sorted(missing)[:10]:
        logger.info("  未移行: %s", name)
    return missing, src


def _rewrite_text(text: str) -> tuple[str, int]:
    old_base = _supabase_public_base()
    new_base = image_storage.R2_PUBLIC_BASE_URL + "/"
    count = text.count(old_base)
    return text.replace(old_base, new_base), count


def phase_rewrite(client, rewrite_files: list[str], execute: bool) -> None:
    old_base = _supabase_public_base()

    # 1. enrichments の画像 URL
    rows = fetch_paginated(client, "enrichments", ENRICHMENT_IMAGE_COLUMNS)
    changed_rows = 0
    for row in rows:
        raw = json.dumps(
            {k: row.get(k) for k in
             ("suumo_images", "floor_plan_images", "best_thumbnail_url")},
            ensure_ascii=False,
        )
        if old_base not in raw:
            continue
        rewritten, _ = _rewrite_text(raw)
        payload = json.loads(rewritten)
        changed_rows += 1
        if execute:
            try:
                (client.table("enrichments")
                 .update(payload)
                 .eq("listing_id", row["listing_id"])
                 .execute())
            except Exception as e:
                logger.error("enrichments 書き換え失敗 (listing_id=%s): %s",
                             row.get("listing_id"), e)
    logger.info("enrichments URL 書き換え: %d行%s",
                changed_rows, "" if execute else "（dry-run）")

    # 2. マニフェスト
    manifest = _load_manifest()
    rewritten_manifest = {}
    manifest_changed = 0
    for orig, stored in manifest.items():
        new_stored, count = _rewrite_text(stored)
        rewritten_manifest[orig] = new_stored
        manifest_changed += count
    if execute and manifest_changed:
        _save_manifest(rewritten_manifest)
    logger.info("マニフェスト URL 書き換え: %d件 (%s)%s",
                manifest_changed, MANIFEST_PATH, "" if execute else "（dry-run）")

    # 3. 指定 JSON ファイル（results/latest.json 等）
    for file_path in rewrite_files:
        path = Path(file_path)
        if not path.exists():
            logger.warning("ファイルなしのためスキップ: %s", path)
            continue
        text = path.read_text(encoding="utf-8")
        new_text, count = _rewrite_text(text)
        if execute and count:
            tmp = path.with_suffix(path.suffix + ".tmp")
            tmp.write_text(new_text, encoding="utf-8")
            tmp.replace(path)
        logger.info("%s: %d箇所書き換え%s", path, count, "" if execute else "（dry-run）")


def phase_delete_source(client, execute: bool) -> None:
    missing, src = phase_verify(client)
    if not src:
        logger.info("Supabase 側にオブジェクトなし。終了")
        return
    deletable = sorted(set(src) - missing)
    logger.info("削除対象（R2 移行検証済み）: %d/%d件", len(deletable), len(src))
    if missing:
        logger.warning("未移行 %d件は削除しない。copy フェーズを再実行してください", len(missing))
    if not execute:
        logger.info("[dry-run] --execute で実削除します")
        return

    deleted = image_storage.delete_supabase_objects(client, deletable)
    logger.info("Supabase Storage 削除完了: %d/%d件", deleted, len(deletable))


def main() -> None:
    parser = argparse.ArgumentParser(description="listing-images を R2 へ移行する")
    parser.add_argument("--phase", required=True,
                        choices=["copy", "verify", "rewrite", "delete-source"])
    parser.add_argument("--execute", action="store_true",
                        help="rewrite / delete-source で実変更を行う")
    parser.add_argument("--rewrite-file", action="append", default=[],
                        help="rewrite フェーズで URL を書き換えるファイル（複数指定可）")
    args = parser.parse_args()

    if not image_storage.r2_configured():
        logger.error("R2_* 環境変数が未設定のため中止")
        sys.exit(1)
    client = get_client()
    if client is None:
        logger.error("SUPABASE_URL/SERVICE_ROLE_KEY 未設定のため中止")
        sys.exit(1)

    if args.phase == "copy":
        failed = phase_copy(client)
        sys.exit(1 if failed else 0)
    elif args.phase == "verify":
        missing, _ = phase_verify(client)
        sys.exit(1 if missing else 0)
    elif args.phase == "rewrite":
        phase_rewrite(client, args.rewrite_file, args.execute)
    elif args.phase == "delete-source":
        phase_delete_source(client, args.execute)


if __name__ == "__main__":
    main()
