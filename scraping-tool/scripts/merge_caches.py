#!/usr/bin/env python3
"""
複数ジョブが独立更新したキャッシュファイルを union マージする。

使い方:
  python3 merge_caches.py --base data/geocode_cache.json \
    --updates chuko/geocode_cache.json shinchiku/geocode_cache.json \
    --output data/geocode_cache.json

ロジック:
  1. base ファイルを読み込み (なければ空 dict)
  2. 各 update ファイルを順にマージ (dict.update で新エントリ追加、既存キーは上書き)
  3. 結果を output に書き出し

対象キャッシュ:
  - geocode_cache.json (address → {lat, lng, ...})
  - sumai_surfin_cache.json (name → {...})
  - floor_plan_storage_manifest.json (url → storage_url)
  - station_cache.json (station_name → {lat, lng})
  - reverse_geocode_cache.json (lat_lng → address)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load_json_dict(path: Path) -> dict:
    """JSON dict を安全に読み込む。失敗時は空 dict。"""
    if not path.exists():
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
        print(f"[merge_caches] 警告: {path} が dict ではありません（スキップ）", file=sys.stderr)
        return {}
    except (json.JSONDecodeError, OSError) as e:
        print(f"[merge_caches] 警告: {path} の読み込みに失敗: {e}", file=sys.stderr)
        return {}


def main() -> None:
    parser = argparse.ArgumentParser(description="キャッシュファイルの union マージ")
    parser.add_argument("--base", required=True, help="ベースキャッシュファイル")
    parser.add_argument("--updates", nargs="+", required=True, help="マージするキャッシュファイル群")
    parser.add_argument("--output", required=True, help="出力先")
    args = parser.parse_args()

    merged = load_json_dict(Path(args.base))
    base_count = len(merged)

    for update_path_str in args.updates:
        update_path = Path(update_path_str)
        update_data = load_json_dict(update_path)
        if update_data:
            new_keys = len(set(update_data.keys()) - set(merged.keys()))
            merged.update(update_data)
            print(
                f"[merge_caches] {update_path}: {new_keys} 新規エントリ, "
                f"{len(update_data) - new_keys} 上書き",
                file=sys.stderr,
            )

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(merged, f, ensure_ascii=False, indent=2)

    print(
        f"[merge_caches] 完了: {base_count} → {len(merged)} エントリ ({args.output})",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
