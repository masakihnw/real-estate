#!/usr/bin/env python3
"""Supabase上の重複identity_keyを検出し、7要素版を残して旧行をis_active=falseにする。

一時実行スクリプト。identity_key が6要素→7要素に変わった際に
旧行が残存している問題を解消する。

Usage:
    python scripts/cleanup_supabase_duplicates.py          # dry-run
    python scripts/cleanup_supabase_duplicates.py --apply  # 実行
"""

import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from supabase_client import get_client


def main():
    apply = "--apply" in sys.argv
    client = get_client()
    if not client:
        print("ERROR: Supabase client not available (check SUPABASE_SERVICE_ROLE_KEY)")
        sys.exit(1)

    print("Fetching all active listings...")
    all_listings = []
    offset = 0
    while True:
        resp = (client.table("listings")
                .select("id, identity_key, normalized_name, area_m2, layout, property_type, updated_at")
                .eq("is_active", True)
                .range(offset, offset + 999)
                .execute())
        if not resp.data:
            break
        all_listings.extend(resp.data)
        offset += 1000

    print(f"  Total active listings: {len(all_listings)}")

    # グルーピング: normalized_name + area_m2 + layout + property_type
    groups = defaultdict(list)
    for row in all_listings:
        key = (
            row.get("normalized_name") or "",
            row.get("area_m2"),
            row.get("layout") or "",
            row.get("property_type") or "",
        )
        groups[key].append(row)

    # 重複検出
    duplicates_found = 0
    deactivate_ids = []

    for group_key, rows in groups.items():
        if len(rows) < 2:
            continue
        duplicates_found += 1

        # 7要素key（floor付き）を優先、同じ要素数なら updated_at が新しい方
        def sort_key(r):
            ik = r.get("identity_key") or ""
            parts = ik.split("|")
            has_floor = len(parts) == 7 and parts[6] not in ("None", "")
            return (has_floor, r.get("updated_at") or "")

        rows_sorted = sorted(rows, key=sort_key, reverse=True)
        keep = rows_sorted[0]
        remove = rows_sorted[1:]

        print(f"\n  DUP: {group_key[0]} | {group_key[2]} | {group_key[1]}m²")
        print(f"    KEEP:   id={keep['id']} ik={keep['identity_key']}")
        for r in remove:
            print(f"    REMOVE: id={r['id']} ik={r['identity_key']}")
            deactivate_ids.append(r["id"])

    print(f"\n{'='*60}")
    print(f"Duplicate groups: {duplicates_found}")
    print(f"Listings to deactivate: {len(deactivate_ids)}")

    if not deactivate_ids:
        print("Nothing to do.")
        return

    if not apply:
        print("\nDry-run mode. Use --apply to execute.")
        return

    print("\nApplying deactivations...")
    for lid in deactivate_ids:
        client.table("listings").update({"is_active": False}).eq("id", lid).execute()
        # Also deactivate all sources for this listing
        client.table("listing_sources").update({"is_active": False}).eq("listing_id", lid).execute()
    print(f"Done. Deactivated {len(deactivate_ids)} duplicate listings.")


if __name__ == "__main__":
    main()
