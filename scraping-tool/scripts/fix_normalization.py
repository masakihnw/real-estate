#!/usr/bin/env python3
"""物件名正規化バグ修正マイグレーション。

normalize_listing_name / identity_key_str の修正を既存データに適用する:
1. 【建物名】特徴タグ×特徴タグ → 建物名 (normalized_name 修正)
2. 号室/丁目 suffix 除去
3. ☆以降の広告テキスト除去
4. area_m2 の float 表記統一 (70.0 → 70)
5. identity_key 衝突時はレコードをマージ

Usage:
    python scripts/fix_normalization.py          # dry-run
    python scripts/fix_normalization.py --apply  # 実行
"""

import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from report_utils import normalize_listing_name, _format_key_element
from supabase_client import get_client


def _rebuild_identity_key(row: dict) -> str:
    name = row.get("name") or ""
    layout = (row.get("layout") or "").strip()
    area = row.get("area_m2")
    address = row.get("address") or ""
    built_year = row.get("built_year")
    floor = row.get("floor_position")

    # normalize address (same logic as _normalize_address_for_key)
    import unicodedata, re
    addr = unicodedata.normalize("NFKC", address).strip()
    if addr.startswith("東京都"):
        addr = addr[3:]
    addr = re.sub(r"(\d+)\s*[-ー－/／].*$", r"\1", addr)
    addr = re.sub(r"(\d+)丁目$", r"\1", addr)

    parts = (
        normalize_listing_name(name),
        layout,
        area,
        addr,
        built_year,
        floor if floor is not None else None,
    )
    return "|".join(_format_key_element(x) for x in parts)


def main():
    apply = "--apply" in sys.argv
    client = get_client()
    if not client:
        print("ERROR: Supabase client not available (check SUPABASE_SERVICE_ROLE_KEY)")
        sys.exit(1)

    print("全 active listings を取得中...")
    all_listings: list[dict] = []
    offset = 0
    while True:
        resp = (client.table("listings")
                .select("id, identity_key, name, normalized_name, address, layout, area_m2, built_year, floor_position, is_active")
                .eq("is_active", True)
                .range(offset, offset + 999)
                .execute())
        if not resp.data:
            break
        all_listings.extend(resp.data)
        if len(resp.data) < 1000:
            break
        offset += 1000

    print(f"  active レコード数: {len(all_listings)}")

    changes: list[dict] = []
    for row in all_listings:
        new_normalized = normalize_listing_name(row["name"] or "")
        new_ik = _rebuild_identity_key(row)
        old_ik = row["identity_key"]

        if new_ik != old_ik or new_normalized != (row["normalized_name"] or ""):
            changes.append({
                "id": row["id"],
                "name": row["name"],
                "old_normalized": row["normalized_name"],
                "new_normalized": new_normalized,
                "old_ik": old_ik,
                "new_ik": new_ik,
            })

    print(f"  変更対象: {len(changes)}件")

    if not changes:
        print("変更対象なし")
        return

    # identity_key 衝突グループを検出
    # 既存レコードの identity_key セット
    existing_iks: dict[str, int] = {r["identity_key"]: r["id"] for r in all_listings}

    # 変更後の identity_key でグループ化（変更なしのレコードも含む）
    ik_to_ids: dict[str, list[int]] = defaultdict(list)
    for row in all_listings:
        new_ik = _rebuild_identity_key(row)
        ik_to_ids[new_ik].append(row["id"])

    # 衝突グループ（2件以上が同一 identity_key に集約）
    conflicts = {k: v for k, v in ik_to_ids.items() if len(v) >= 2}

    print(f"\n--- 変更一覧 ---")
    for c in changes:
        conflict_marker = " [CONFLICT]" if c["new_ik"] in conflicts else ""
        print(f"  id={c['id']}: {c['name'][:50]}")
        print(f"    normalized: {c['old_normalized'][:40]} → {c['new_normalized'][:40]}")
        if c["old_ik"] != c["new_ik"]:
            print(f"    ik: ...{c['old_ik'][-40:]} → ...{c['new_ik'][-40:]}{conflict_marker}")

    print(f"\n--- 衝突グループ ({len(conflicts)}件) ---")
    merge_plans: list[dict] = []
    for ik, ids in sorted(conflicts.items()):
        ids.sort()
        rows = [r for r in all_listings if r["id"] in ids]
        # 77793 を優先残し（ユーザー確認済み）、それ以外は新しい方を残す
        if 77793 in ids:
            keep_id = 77793
        else:
            keep_id = ids[0]

        delete_ids = [i for i in ids if i != keep_id]
        keep_row = next(r for r in rows if r["id"] == keep_id)
        print(f"  ik={ik[:60]}")
        print(f"    KEEP id={keep_id} ({keep_row['name'][:40]})")
        for did in delete_ids:
            d_row = next(r for r in rows if r["id"] == did)
            print(f"    DEL  id={did} ({d_row['name'][:40]})")

        merge_plans.append({"keep_id": keep_id, "delete_ids": delete_ids, "new_ik": ik})

    if not apply:
        print(f"\nDry-run mode. Use --apply to execute.")
        return

    print(f"\n--- 実行中 ---")

    # Phase 1: マージ（衝突解消）
    for plan in merge_plans:
        keep_id = plan["keep_id"]
        for did in plan["delete_ids"]:
            print(f"  マージ: {did} → {keep_id}")

            # listing_sources を移行
            try:
                client.table("listing_sources").update(
                    {"listing_id": keep_id}
                ).eq("listing_id", did).execute()
            except Exception:
                # ON CONFLICT の場合は個別削除（既に存在するsource）
                client.table("listing_sources").delete().eq("listing_id", did).execute()

            # price_history を移行
            try:
                existing_ph = client.table("price_history").select("*").eq("listing_id", did).execute()
                for ph in (existing_ph.data or []):
                    try:
                        client.table("price_history").insert({
                            "listing_id": keep_id,
                            "source": ph.get("source"),
                            "price_man": ph.get("price_man"),
                            "recorded_at": ph.get("recorded_at"),
                        }).execute()
                    except Exception:
                        pass
                client.table("price_history").delete().eq("listing_id", did).execute()
            except Exception as e:
                print(f"    price_history 移行エラー: {e}")

            # listing_events を移行
            try:
                client.table("listing_events").update(
                    {"listing_id": keep_id}
                ).eq("listing_id", did).execute()
            except Exception:
                client.table("listing_events").delete().eq("listing_id", did).execute()

            # listing_facts を移行
            try:
                client.table("listing_facts").delete().eq("identity_key",
                    next(r["identity_key"] for r in all_listings if r["id"] == did)
                ).execute()
            except Exception:
                pass

            # near_misses を移行
            try:
                client.table("near_misses").delete().eq("identity_key",
                    next(r["identity_key"] for r in all_listings if r["id"] == did)
                ).execute()
            except Exception:
                pass

            # enrichments と listings を削除
            client.table("enrichments").delete().eq("listing_id", did).execute()
            client.table("listings").delete().eq("id", did).execute()
            print(f"    削除完了: id={did}")

    # Phase 2: 残存レコードの identity_key / normalized_name 更新
    updated = 0
    for c in changes:
        # マージで削除されたレコードはスキップ
        deleted_ids = set()
        for plan in merge_plans:
            deleted_ids.update(plan["delete_ids"])
        if c["id"] in deleted_ids:
            continue

        try:
            client.table("listings").update({
                "identity_key": c["new_ik"],
                "normalized_name": c["new_normalized"],
            }).eq("id", c["id"]).execute()
            updated += 1
        except Exception as e:
            print(f"  UPDATE エラー id={c['id']}: {e}")

    # Phase 3: listing_facts / near_misses の identity_key も更新
    for c in changes:
        if c["id"] in deleted_ids:
            continue
        if c["old_ik"] == c["new_ik"]:
            continue
        try:
            client.table("listing_facts").update(
                {"identity_key": c["new_ik"]}
            ).eq("identity_key", c["old_ik"]).execute()
        except Exception:
            pass
        try:
            client.table("near_misses").update(
                {"identity_key": c["new_ik"]}
            ).eq("identity_key", c["old_ik"]).execute()
        except Exception:
            pass

    print(f"\n完了: マージ {len(merge_plans)}グループ, 更新 {updated}件")


if __name__ == "__main__":
    main()
