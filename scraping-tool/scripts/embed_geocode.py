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
import re
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


def _normalize_address(address: str) -> str:
    """住所を正規化してキャッシュ照合しやすくする。
    - 「（地番）」「（地名地番）」「他」「以下略」等の末尾を除去
    - 番地の詳細部分（XX番YY号、XX-YY-ZZ）を丁目レベルに縮める
    """
    s = address.strip()
    # 括弧付き注記を除去: （地番）、（地名地番）、(地番) 等
    s = re.sub(r"[（(][^）)]*地番[^）)]*[）)]", "", s).strip()
    s = re.sub(r"[（(][^）)]*[）)]$", "", s).strip()
    # 末尾の「他」「以下略」を除去
    s = re.sub(r"[、,]\s*他\s*$", "", s).strip()
    s = re.sub(r"\s*他\s*$", "", s).strip()
    return s


def _address_candidates(address: str) -> list[str]:
    """住所のキャッシュ照合候補を生成（完全一致 → 正規化 → 段階的に短縮）。"""
    candidates = [address]

    # 「東京都」prefix 付き
    if not address.startswith("東京都"):
        candidates.append(f"東京都{address}")

    # 正規化版
    norm = _normalize_address(address)
    if norm != address:
        candidates.append(norm)
        if not norm.startswith("東京都"):
            candidates.append(f"東京都{norm}")

    # 番地の詳細を段階的に削って候補を追加
    # 例: "東京都港区芝5丁目2番93" → "東京都港区芝5丁目2番" → "東京都港区芝5丁目" → "東京都港区芝５"
    base = norm if norm.startswith("東京都") else f"東京都{norm}"
    # 「X番Y号」「X番Y」「X-Y-Z」を段階的に削る
    patterns = [
        r"\d+号$",                    # XX号 を除去
        r"\d+番\d*$",                 # XX番YY を除去
        r"-\d+$",                     # 末尾の -XX を除去（複数回）
        r"-\d+$",                     # もう1段
        r"\d+番地?\s*$",              # XX番地 を除去
    ]
    shortened = base
    for pat in patterns:
        prev = shortened
        shortened = re.sub(pat, "", shortened).strip()
        if shortened != prev and shortened not in candidates:
            candidates.append(shortened)

    # 丁目表記の揺れ: 「二丁目」→「2丁目」→「２」、「３丁目」→「３」
    kanji_num = {"一": "1", "二": "2", "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9", "十": "10"}
    for cand in list(candidates):
        # 漢数字丁目 → アラビア数字丁目
        converted = cand
        for k_char, a_char in kanji_num.items():
            converted = converted.replace(f"{k_char}丁目", f"{a_char}丁目")
        if converted != cand and converted not in candidates:
            candidates.append(converted)
        # 「X丁目」→ 除去して丁目なし表記（例: "人形町３丁目" → "人形町３"）
        no_chome = re.sub(r"(\d+)丁目.*$", r"\1", converted).strip()
        if no_chome != converted and no_chome not in candidates:
            candidates.append(no_chome)
        # 全角数字 ↔ 半角数字の揺れ
        zen = converted.translate(str.maketrans("0123456789", "０１２３４５６７８９"))
        han = converted.translate(str.maketrans("０１２３４５６７８９", "0123456789"))
        for v in (zen, han):
            if v != converted and v not in candidates:
                candidates.append(v)

    return candidates


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
        # 段階的にアドレス候補を生成してキャッシュを照合
        coord = None
        for candidate in _address_candidates(address):
            coord = cache.get(candidate)
            if coord:
                break
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
