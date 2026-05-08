"""Finalize パイプラインで毎回実行される SQLite 同期スクリプト。

JSON (latest.json / latest_shinchiku.json) → SQLite DB への差分同期を行う。
db.sync_scrape_results() を呼び、新規/更新/削除イベントを記録する。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from db import get_db, sync_scrape_results


def _cleanup_db_duplicates(conn) -> int:
    """旧 identity_key（駅名入り/住所未正規化）で生まれた重複を検出し削除する。"""
    import re
    import unicodedata
    from collections import defaultdict

    def normalize_prefix(ik: str) -> str:
        parts = ik.split("|")
        if len(parts) < 5:
            return ik
        addr = unicodedata.normalize("NFKC", parts[3]).strip()
        if addr.startswith("東京都"):
            addr = addr[3:]
        addr = re.sub(r"(\d+)丁目$", r"\1", addr)
        addr = re.sub(r"(\d+)\s*[-ー－/／].*$", r"\1", addr)
        # 番地レベルの差異を吸収: 「富久町12」→「富久町」
        addr = re.sub(r"([一-鿿])\d+$", r"\1", addr)
        return f"{parts[0]}|{parts[1]}|{parts[2]}|{addr}|{parts[4]}"

    rows = conn.execute(
        "SELECT id, identity_key, is_active, updated_at FROM listings"
    ).fetchall()

    groups: dict[str, list] = defaultdict(list)
    for r in rows:
        groups[normalize_prefix(r["identity_key"])].append(dict(r))

    deleted = 0
    for prefix, members in groups.items():
        if len(members) < 2:
            continue
        members.sort(key=lambda r: (r["is_active"], r["updated_at"] or ""), reverse=True)
        for dup in members[1:]:
            lid = dup["id"]
            conn.execute("DELETE FROM listing_sources WHERE listing_id = ?", (lid,))
            conn.execute("DELETE FROM enrichments WHERE listing_id = ?", (lid,))
            conn.execute("DELETE FROM price_history WHERE listing_id = ?", (lid,))
            conn.execute("DELETE FROM listing_events WHERE listing_id = ?", (lid,))
            conn.execute("DELETE FROM listings WHERE id = ?", (lid,))
            deleted += 1
    if deleted:
        conn.commit()
    return deleted


def _load_json(path: str) -> list[dict]:
    p = Path(path)
    if not p.exists() or p.stat().st_size == 0:
        return []
    with open(p) as f:
        data = json.load(f)
    return data if isinstance(data, list) else []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="results")
    parser.add_argument("--db", default=None)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    conn = get_db(args.db)

    # Sync chuko listings
    chuko_path = output_dir / "latest.json"
    chuko = _load_json(str(chuko_path))
    if chuko:
        sources_in_batch: dict[str, list[dict]] = {}
        for item in chuko:
            src = item.get("source", "suumo")
            sources_in_batch.setdefault(src, []).append(item)

        for source, items in sources_in_batch.items():
            summary = sync_scrape_results(conn, items, source, property_type="chuko")
            print(
                f"[sync_db] {source}(中古): "
                f"new={summary['new']} updated={summary['updated']} "
                f"removed={summary['removed']} reappeared={summary['reappeared']}",
                file=sys.stderr,
            )
    else:
        print("[sync_db] latest.json が空またはなし（スキップ）", file=sys.stderr)

    # Sync shinchiku listings
    shinchiku_path = output_dir / "latest_shinchiku.json"
    shinchiku = _load_json(str(shinchiku_path))
    if shinchiku:
        sources_in_batch: dict[str, list[dict]] = {}
        for item in shinchiku:
            src = item.get("source", "suumo")
            sources_in_batch.setdefault(src, []).append(item)

        for source, items in sources_in_batch.items():
            summary = sync_scrape_results(conn, items, source, property_type="shinchiku")
            print(
                f"[sync_db] {source}(新築): "
                f"new={summary['new']} updated={summary['updated']} "
                f"removed={summary['removed']} reappeared={summary['reappeared']}",
                file=sys.stderr,
            )
    else:
        print("[sync_db] latest_shinchiku.json が空またはなし（スキップ）", file=sys.stderr)

    # 旧 identity_key の重複クリーンアップ
    cleaned = _cleanup_db_duplicates(conn)
    if cleaned:
        print(f"[sync_db] DB重複クリーンアップ: {cleaned}件削除", file=sys.stderr)

    # Print stats
    total = conn.execute("SELECT COUNT(*) AS cnt FROM listings WHERE is_active = 1").fetchone()["cnt"]
    total_all = conn.execute("SELECT COUNT(*) AS cnt FROM listings").fetchone()["cnt"]
    print(f"[sync_db] DB状態: active={total}, total={total_all}", file=sys.stderr)

    conn.close()

    # Supabase 並行同期
    # USE_SUPABASE_EXPORT=1 時は enricher が直接書き込み済みのためスキップ
    import os
    if os.environ.get("USE_SUPABASE_EXPORT") == "1":
        print("[sync_db] USE_SUPABASE_EXPORT=1: Supabase 同期スキップ（dual-write 済み）", file=sys.stderr)
    else:
        try:
            from supabase_sync import sync_to_supabase
            sync_to_supabase(str(output_dir))
        except Exception as e:
            print(f"[sync_db] Supabase 同期失敗（非致命的）: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
