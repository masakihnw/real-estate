#!/usr/bin/env python3
"""
ジオコーディングキャッシュ（data/geocode_cache.json）の座標を
物件 JSON（latest.json 等）に埋め込む。

ネットワークアクセスは一切行わない（キャッシュにある座標のみ使用）。
新規住所のジオコーディングは build_map_viewer.py が行う。

使い方:
  python scripts/embed_geocode.py results/latest.json
  python scripts/embed_geocode.py results/latest_shinchiku.json
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE_PATH = ROOT / "data" / "geocode_cache.json"


def load_cache() -> dict:
    """geocode_cache.json を読み込み、{address: (lat, lon)} の辞書を返す。"""
    if not CACHE_PATH.exists():
        return {}
    try:
        with open(CACHE_PATH, encoding="utf-8") as f:
            data = json.load(f)
        result = {}
        for k, v in data.items():
            if isinstance(v, (list, tuple)) and len(v) >= 2:
                result[k] = (float(v[0]), float(v[1]))
        return result
    except (json.JSONDecodeError, TypeError, OSError) as e:
        print(f"警告: geocode キャッシュ読み込み失敗: {e}", file=sys.stderr)
        return {}


def embed(json_path: Path) -> int:
    """
    JSON ファイル内の物件に geocode_cache の座標を埋め込む。
    埋め込んだ件数を返す。
    """
    cache = load_cache()
    if not cache:
        print("geocode_cache.json が空またはなし。スキップ。", file=sys.stderr)
        return 0

    with open(json_path, encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        print(f"Error: {json_path} is not a JSON array", file=sys.stderr)
        return 0

    embedded_count = 0
    for listing in listings:
        address = (listing.get("address") or "").strip()
        if not address:
            continue
        # 既に座標がある場合はスキップ（スクレイパーやアプリ側で設定済み）
        if listing.get("latitude") is not None and listing.get("longitude") is not None:
            continue
        # 完全一致 → 「東京都」prefix 付きで再試行
        coord = cache.get(address) or cache.get(f"東京都{address}")
        if coord:
            lat, lon = coord
            listing["latitude"] = lat
            listing["longitude"] = lon
            embedded_count += 1

    # 原子的書き込み
    tmp_path = json_path.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp_path.replace(json_path)

    return embedded_count


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <json_path>", file=sys.stderr)
        sys.exit(1)

    json_path = Path(sys.argv[1])
    if not json_path.exists():
        print(f"Error: {json_path} not found", file=sys.stderr)
        sys.exit(1)

    count = embed(json_path)
    total = 0
    with open(json_path, encoding="utf-8") as f:
        total = len(json.load(f))
    print(f"座標埋め込み: {count}/{total}件（キャッシュから）", file=sys.stderr)


if __name__ == "__main__":
    main()
