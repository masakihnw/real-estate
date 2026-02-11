#!/usr/bin/env python3
"""
住所を緯度・経度に変換（OpenStreetMap Nominatim）。結果は data/geocode_cache.json にキャッシュ。
"""

import json
import re
import time
from pathlib import Path
from typing import Optional, Tuple

import requests

CACHE_PATH = Path(__file__).resolve().parent.parent / "data" / "geocode_cache.json"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "real-estate-map-viewer/1.0 (personal project; low request rate)"
RATE_LIMIT_SEC = 1.1  # Nominatim 利用ポリシー: 1 req/sec


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


GEOCODE_RETRIES = 3
GEOCODE_BACKOFF_SEC = 2


def geocode(address: str) -> Optional[Tuple[float, float]]:
    """
    住所文字列を (lat, lon) に変換。キャッシュにあればそれを返し、なければ Nominatim に問い合わせる。
    """
    if not address or not address.strip():
        return None
    key = address.strip()
    cache = _load_cache()
    if key in cache:
        return cache[key]
    for strip_num in (False, True):  # まずフル住所、ヒットしなければ町名のみ
        query = _address_to_nominatim_query(key, strip_number=strip_num)
        params = {"q": query, "format": "json", "limit": 1}
        headers = {"User-Agent": USER_AGENT}
        for attempt in range(GEOCODE_RETRIES):
            try:
                time.sleep(RATE_LIMIT_SEC)
                r = requests.get(NOMINATIM_URL, params=params, headers=headers, timeout=10)
                r.raise_for_status()
                data = r.json()
                if data:
                    lat = float(data[0]["lat"])
                    lon = float(data[0]["lon"])
                    cache[key] = (lat, lon)
                    _save_cache(cache)
                    return (lat, lon)
                break  # 空結果ならリトライ不要
            except (requests.RequestException, KeyError, ValueError, TypeError):
                if attempt < GEOCODE_RETRIES - 1:
                    time.sleep(GEOCODE_BACKOFF_SEC * (attempt + 1))
                else:
                    break
    return None
