#!/usr/bin/env python3
"""
現在結果と前回結果を比較し、差分があれば exit 0、なければ exit 1 で終了する。
同一物件は identity_key（名前・間取り・広さ・住所・築年・駅徒歩。価格は除く）で判定。
Notion に同期する全プロパティ（価格・階数・総戸数・権利形態など）の変更を updated としてカウントする。
update_listings.sh で「変更時のみレポート・通知」するために使用。
"""
import sys
from pathlib import Path

from report_utils import identity_key, listing_has_property_changes, load_json


def main() -> None:
    if len(sys.argv) != 3:
        print("使い方: python check_changes.py <current.json> <previous.json>", file=sys.stderr)
        sys.exit(2)

    current_path = Path(sys.argv[1])
    previous_path = Path(sys.argv[2])

    if not current_path.exists():
        sys.exit(2)
    if not previous_path.exists():
        sys.exit(0)

    current = load_json(current_path)
    previous = load_json(previous_path)

    curr_by_key = {identity_key(r): r for r in current}
    prev_by_key = {identity_key(r): r for r in previous}

    new = sum(1 for k in curr_by_key if k not in prev_by_key)
    removed = sum(1 for k in prev_by_key if k not in curr_by_key)
    updated = sum(
        1
        for k in curr_by_key
        if k in prev_by_key and listing_has_property_changes(curr_by_key[k], prev_by_key[k])
    )

    has_changes = new > 0 or removed > 0 or updated > 0
    sys.exit(0 if has_changes else 1)


if __name__ == "__main__":
    main()
