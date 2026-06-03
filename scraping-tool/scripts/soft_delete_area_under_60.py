#!/usr/bin/env python3
"""面積60㎡未満かつ例外エリア外の既存物件を is_active=FALSE にする。

面積下限ルール変更（デフォルト55→60㎡、都心3区・湾岸は55㎡維持）に伴う
一回限りのクリーンアップスクリプト。

Usage:
    python scripts/soft_delete_area_under_60.py          # dry-run
    python scripts/soft_delete_area_under_60.py --apply  # 実行
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from supabase_client import get_client
from scraper_common import get_effective_area_min_m2


def main() -> None:
    apply = "--apply" in sys.argv
    client = get_client()
    if not client:
        print("ERROR: Supabase クライアントが利用できません（SUPABASE_SERVICE_ROLE_KEY を確認）")
        sys.exit(1)

    candidates: list[dict] = []
    offset = 0
    while True:
        resp = (
            client.table("listings")
            .select("id, identity_key, name, address, area_m2")
            .eq("is_active", True)
            .lt("area_m2", 60)
            .gte("area_m2", 1)
            .range(offset, offset + 999)
            .execute()
        )
        if not resp.data:
            break
        candidates.extend(resp.data)
        if len(resp.data) < 1000:
            break
        offset += 1000

    print(f"候補: {len(candidates)} 件 (area_m2 < 60 かつ is_active=TRUE)")

    to_deactivate: list[dict] = []
    to_keep: list[dict] = []
    for row in candidates:
        address = row.get("address") or ""
        effective_min = get_effective_area_min_m2(address)
        area = row.get("area_m2")
        if area is not None and area < effective_min:
            to_deactivate.append(row)
        else:
            to_keep.append(row)

    print(f"ソフトデリート対象: {len(to_deactivate)} 件")
    print(f"例外エリアのため維持: {len(to_keep)} 件")

    for row in to_deactivate:
        tag = "DELETE" if apply else "DRY-RUN"
        print(
            f"  [{tag}] id={row['id']} area={row['area_m2']}㎡ "
            f"addr={str(row.get('address', ''))[:40]} "
            f"name={str(row.get('name', ''))[:30]}"
        )

    if to_keep:
        print("\n例外エリア維持リスト:")
        for row in to_keep:
            print(
                f"  [KEEP] id={row['id']} area={row['area_m2']}㎡ "
                f"addr={str(row.get('address', ''))[:40]}"
            )

    if apply and to_deactivate:
        ids = [r["id"] for r in to_deactivate]
        for i in range(0, len(ids), 100):
            chunk = ids[i : i + 100]
            client.table("listings").update({"is_active": False}).in_("id", chunk).execute()
        print(f"\n完了: {len(to_deactivate)} 件を is_active=FALSE に設定")
    elif not apply and to_deactivate:
        print("\n(dry-run: 実際の変更はありません。--apply で実行)")


if __name__ == "__main__":
    main()
