#!/usr/bin/env python3
"""
住所を緯度・経度に変換（OpenStreetMap Nominatim）。結果は data/geocode_cache.json にキャッシュ。
ジオコーディング結果は東京23区の範囲内かバリデーションし、範囲外の場合は棄却する。
"""

import json
import math
import re
import sys
import time
from pathlib import Path
from typing import Optional, Tuple

import requests

CACHE_PATH = Path(__file__).resolve().parent.parent / "data" / "geocode_cache.json"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "real-estate-map-viewer/1.0 (personal project; low request rate)"
RATE_LIMIT_SEC = 1.1  # Nominatim 利用ポリシー: 1 req/sec

# --- 座標バリデーション ---
# 東京23区の緯度経度の概略範囲
TOKYO_23KU_LAT_MIN = 35.50
TOKYO_23KU_LAT_MAX = 35.90
TOKYO_23KU_LON_MIN = 139.50
TOKYO_23KU_LON_MAX = 140.00

# 各区の概略中心座標（バリデーション用）
_WARD_CENTERS: dict[str, Tuple[float, float]] = {
    "千代田区": (35.694, 139.754), "中央区": (35.671, 139.772),
    "港区": (35.658, 139.752), "新宿区": (35.694, 139.703),
    "文京区": (35.712, 139.752), "台東区": (35.713, 139.783),
    "墨田区": (35.711, 139.801), "江東区": (35.672, 139.817),
    "品川区": (35.609, 139.730), "目黒区": (35.634, 139.698),
    "大田区": (35.561, 139.716), "世田谷区": (35.646, 139.653),
    "渋谷区": (35.664, 139.698), "中野区": (35.708, 139.664),
    "杉並区": (35.700, 139.637), "豊島区": (35.726, 139.716),
    "北区": (35.753, 139.734), "荒川区": (35.736, 139.783),
    "板橋区": (35.752, 139.694), "練馬区": (35.736, 139.652),
    "足立区": (35.776, 139.805), "葛飾区": (35.742, 139.847),
    "江戸川区": (35.707, 139.868),
}

# 区中心からこの距離(km)以内を有効とみなす（区の最大半径 + マージン）
_MAX_WARD_RADIUS_KM = 8.0


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """2点間の距離 (km) をHaversine公式で計算。"""
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2) ** 2
    return R * 2 * math.asin(math.sqrt(a))


def _extract_ward(address: str) -> Optional[str]:
    """住所文字列から区名を抽出。

    「東京都港区」→「港区」、「港区」→「港区」
    注意: 単純な [CJK]+区 パターンでは「東京都港区」全体にマッチしてしまうため、
    「都」の後ろの区名を優先抽出する。
    """
    # パターン1: 「都」の後ろの区名（「東京都港区...」→「港区」）
    m = re.search(r"都([^区]+区)", address)
    if m:
        return m.group(1)
    # パターン2: 先頭から短い区名（「港区港南...」→「港区」）
    m = re.search(r"^([^\s都道府県]{1,4}区)", address)
    return m.group(1) if m else None


def validate_tokyo_coordinate(address: str, lat: float, lon: float) -> bool:
    """
    ジオコーディング結果が妥当か検証する。
    1. 東京23区の大枠範囲内であること
    2. 住所から抽出した区の中心座標から一定距離内であること
    """
    # 東京23区の大枠チェック
    if not (TOKYO_23KU_LAT_MIN <= lat <= TOKYO_23KU_LAT_MAX and
            TOKYO_23KU_LON_MIN <= lon <= TOKYO_23KU_LON_MAX):
        print(f"⚠ バリデーション失敗（東京範囲外）: {address} → [{lat}, {lon}]", file=sys.stderr)
        return False

    # 区の中心からの距離チェック
    ward = _extract_ward(address)
    if ward and ward in _WARD_CENTERS:
        center_lat, center_lon = _WARD_CENTERS[ward]
        dist = _haversine_km(lat, lon, center_lat, center_lon)
        if dist > _MAX_WARD_RADIUS_KM:
            print(f"⚠ バリデーション失敗（{ward}中心から{dist:.1f}km）: {address} → [{lat}, {lon}]", file=sys.stderr)
            return False

    return True


def _load_cache() -> dict:
    if not CACHE_PATH.exists():
        return {}
    try:
        with open(CACHE_PATH, encoding="utf-8") as f:
            data = json.load(f)
        return {k: tuple(v) for k, v in data.items()}
    except (json.JSONDecodeError, TypeError):
        return {}


def _save_cache(cache: dict) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    # 原子的書き込み
    tmp_path = CACHE_PATH.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump({k: list(v) for k, v in cache.items()}, f, ensure_ascii=False, indent=0)
    tmp_path.replace(CACHE_PATH)


def _address_to_nominatim_query(address: str, strip_number: bool = False) -> str:
    """
    日本語住所を Nominatim がヒットしやすい形に変換。
    東京都XX区YY  → YY XX区 東京 Japan
    strip_number=True のときは番地・丁目を除いた町名のみでクエリ（フォールバック用）。
    """
    s = address.strip()
    if not s:
        return s
    m = re.match(r"東京都?([一-龥ぁ-んァ-ン]+区)(.*)", s)
    if m:
        ward = m.group(1)
        rest = (m.group(2) or "").strip()
        if strip_number:
            # 番地・丁目を除去（例: 下落合３ → 下落合、千石２-32-6 → 千石）
            rest = re.sub(r"[０-９0-9一二三四五六七八九十百千\-－\-]+.*$", "", rest).strip()
        if rest:
            return f"{rest} {ward} 東京 Japan"
        return f"{ward} 東京 Japan"
    return f"{s} Japan"


def _address_to_nominatim_query_chome(address: str) -> Optional[str]:
    """
    丁目表記を明示したクエリを生成（フォールバック用）。
    例: 東京都北区東十条１ → 東十条1丁目 北区 東京都 Japan
    """
    s = address.strip()
    m = re.match(r"東京都?([一-龥ぁ-んァ-ン]+区)(.+?)([０-９0-9一二三四五六七八九]+)$", s)
    if not m:
        return None
    ward = m.group(1)
    town = m.group(2).strip()
    num = m.group(3)
    # 全角→半角
    num = num.translate(str.maketrans("０１２３４５６７８９", "0123456789"))
    kanji = {"一": "1", "二": "2", "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"}
    for k, v in kanji.items():
        num = num.replace(k, v)
    return f"{town}{num}丁目 {ward} 東京都 Japan"


GEOCODE_RETRIES = 3
GEOCODE_BACKOFF_SEC = 2


def geocode(address: str) -> Optional[Tuple[float, float]]:
    """
    住所文字列を (lat, lon) に変換。キャッシュにあればそれを返し、なければ Nominatim に問い合わせる。
    結果は東京23区の範囲内かバリデーションし、範囲外なら棄却してフォールバッククエリを試行する。
    """
    if not address or not address.strip():
        return None
    key = address.strip()
    cache = _load_cache()
    if key in cache:
        return cache[key]

    # クエリ候補: フル住所 → 丁目明示 → 町名のみ
    queries = []
    queries.append(_address_to_nominatim_query(key, strip_number=False))
    chome_query = _address_to_nominatim_query_chome(key)
    if chome_query:
        queries.append(chome_query)
    queries.append(_address_to_nominatim_query(key, strip_number=True))

    headers = {"User-Agent": USER_AGENT}
    for query in queries:
        params = {"q": query, "format": "json", "limit": 1, "countrycodes": "jp"}
        for attempt in range(GEOCODE_RETRIES):
            try:
                time.sleep(RATE_LIMIT_SEC)
                r = requests.get(NOMINATIM_URL, params=params, headers=headers, timeout=10)
                r.raise_for_status()
                data = r.json()
                if data:
                    lat = float(data[0]["lat"])
                    lon = float(data[0]["lon"])
                    # バリデーション: 東京23区の範囲内かチェック
                    if validate_tokyo_coordinate(key, lat, lon):
                        cache[key] = (lat, lon)
                        _save_cache(cache)
                        return (lat, lon)
                    else:
                        # バリデーション失敗 → 次のクエリ候補を試行
                        break
                break  # 空結果ならリトライ不要
            except (requests.RequestException, KeyError, ValueError, TypeError):
                if attempt < GEOCODE_RETRIES - 1:
                    time.sleep(GEOCODE_BACKOFF_SEC * (attempt + 1))
                else:
                    break
    return None


def validate_cache() -> list[str]:
    """
    既存キャッシュの全エントリをバリデーションし、問題のあるアドレスのリストを返す。
    """
    cache = _load_cache()
    invalid = []
    for addr, (lat, lon) in cache.items():
        if not validate_tokyo_coordinate(addr, lat, lon):
            invalid.append(addr)
    return invalid


if __name__ == "__main__":
    # スタンドアロンで実行: キャッシュバリデーション
    invalid = validate_cache()
    if invalid:
        print(f"\n❌ {len(invalid)}件の問題エントリが見つかりました:")
        for addr in invalid:
            cache = _load_cache()
            lat, lon = cache[addr]
            print(f"  {addr}: [{lat}, {lon}]")
        print("\nこれらのエントリを削除して再ジオコーディングすることを推奨します。")
        sys.exit(1)
    else:
        total = len(_load_cache())
        print(f"✅ 全{total}件のキャッシュエントリが正常です。")
        sys.exit(0)
