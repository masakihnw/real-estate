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

    # Print stats
    total = conn.execute("SELECT COUNT(*) AS cnt FROM listings WHERE is_active = 1").fetchone()["cnt"]
    total_all = conn.execute("SELECT COUNT(*) AS cnt FROM listings").fetchone()["cnt"]
    print(f"[sync_db] DB状態: active={total}, total={total_all}", file=sys.stderr)

    conn.close()


if __name__ == "__main__":
    main()
