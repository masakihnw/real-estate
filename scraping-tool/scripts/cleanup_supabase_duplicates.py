#!/usr/bin/env python3
"""Supabase の重複 listings レコードをクリーンアップするスクリプト。

同じ物件が identity_key の微妙な差異（徒歩分数、住所フォーマット、
東京都prefix、丁目suffix 等）で複数レコードとして存在���るケースを検出・統合する。

active/inactive 全レコードを対象���し、重複グループ内で最も情報量の多い1件を残し、
残りは関連テーブル含めて完全に削除する。

Usage:
    python scripts/cleanup_supabase_duplicates.py          # dry-run
    python scripts/cleanup_supabase_duplicates.py --apply  # 実行
"""

import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from supabase_client import get_client


def _normalize_key_prefix(ik: str) -> str:
    """identity_key から比較用プレフィックスを抽出。
    名前|間取り|面積|住所(正規化)|築年 で一致判定する。"""
    import re
    import unicodedata
    parts = ik.split("|")
    if len(parts) < 5:
        return ik

    name, layout, area, address, built = parts[0], parts[1], parts[2], parts[3], parts[4]

    # 住所の正規化（東京都除去、丁目除去）
    addr = unicodedata.normalize("NFKC", address).strip()
    if addr.startswith("東京都"):
        addr = addr[3:]
    addr = re.sub(r"(\d+)丁目$", r"\1", addr)
    addr = re.sub(r"(\d+)\s*[-ー－/／].*$", r"\1", addr)

    return f"{name}|{layout}|{area}|{addr}|{built}"


def main():
    apply = "--apply" in sys.argv
    client = get_client()
    if not client:
        print("ERROR: Supabase client not available (check SUPABASE_SERVICE_ROLE_KEY)")
        sys.exit(1)

    print("全 listings を取得中...")
    all_listings: list[dict] = []
    offset = 0
    while True:
        resp = (client.table("listings")
                .select("id, identity_key, name, is_active, updated_at")
                .range(offset, offset + 999)
                .execute())
        if not resp.data:
            break
        all_listings.extend(resp.data)
        if len(resp.data) < 1000:
            break
        offset += 1000

    print(f"  全レコード数: {len(all_listings)}")
    active_count = sum(1 for r in all_listings if r["is_active"])
    print(f"  うち active: {active_count}")

    # 正規化 prefix でグループ化
    groups: dict[str, list[dict]] = defaultdict(list)
    for row in all_listings:
        prefix = _normalize_key_prefix(row["identity_key"])
        groups[prefix].append(row)

    # 重複グループ（2件以上）を抽出
    duplicates = {k: v for k, v in groups.items() if len(v) >= 2}
    print(f"  重複グループ数: {len(duplicates)}")

    total_to_delete = 0
    delete_ids: list[int] = []

    for prefix, rows in sorted(duplicates.items()):
        # 最適なレコードを選択: active > inactive, 新しい updated_at 優先
        rows.sort(key=lambda r: (r["is_active"], r["updated_at"] or ""), reverse=True)
        keep = rows[0]
        to_delete = rows[1:]

        if to_delete:
            print(f"\n  {keep['name'][:40]} (keep id={keep['id']}, active={keep['is_active']})")
            for d in to_delete:
                print(f"    DEL id={d['id']} active={d['is_active']} key=...{d['identity_key'][-30:]}")
                delete_ids.append(d["id"])
                total_to_delete += 1

    print(f"\n{'='*60}")
    print(f"削除対象: {total_to_delete}件（{len(duplicates)}グループ）")

    if not delete_ids:
        print("削除対象なし")
        return

    if not apply:
        print("\nDry-run mode. Use --apply to execute.")
        return

    print("\n削除実行中...")
    deleted = 0
    for i, lid in enumerate(delete_ids):
        client.table("listing_sources").delete().eq("listing_id", lid).execute()
        client.table("enrichments").delete().eq("listing_id", lid).execute()
        client.table("price_history").delete().eq("listing_id", lid).execute()
        client.table("listing_events").delete().eq("listing_id", lid).execute()
        client.table("listings").delete().eq("id", lid).execute()
        deleted += 1
        if (i + 1) % 50 == 0:
            print(f"  {i + 1}/{total_to_delete} 削除済み", file=sys.stderr)

    print(f"\n完了: {deleted}件削除")


if __name__ == "__main__":
    main()
