"""
スクレイパー共通ユーティリティ。

セッション生成、フィルタ補助関数、WAF 検出など、
suumo_scraper / suumo_shinchiku_scraper / homes_scraper / homes_shinchiku_scraper で
共有する副作用を持つ関数群。
"""

import json
import re
import sys
from pathlib import Path
from typing import Optional

import requests

from config import (
    USER_AGENT,
    STATION_PASSENGERS_MIN,
    ALLOWED_LINE_KEYWORDS,
    TOKYO_23_WARDS,
)


# ──────────────────────────── セッション ────────────────────────────


def create_session() -> requests.Session:
    """共通の HTTP セッションを生成。全スクレイパーで同一のヘッダーを使用。"""
    s = requests.Session()
    s.headers["User-Agent"] = USER_AGENT
    s.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    s.headers["Accept-Language"] = "ja,en;q=0.9"
    return s


# ──────────────────────────── WAF 検出 ────────────────────────────


def is_waf_challenge(html: str) -> bool:
    """AWS WAF のボット検知チャレンジページかどうかを判定。HOME'S 用。"""
    if len(html) < 5000 and "awsWafCookieDomainList" in html:
        return True
    if len(html) < 5000 and "gokuProps" in html:
        return True
    return False


# ──────────────────────────── 駅乗降客数 ────────────────────────────


def load_station_passengers() -> dict[str, int]:
    """data/station_passengers.json から 駅名 → 乗降客数 を読み込む。"""
    path = Path(__file__).resolve().parent / "data" / "station_passengers.json"
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def station_name_from_line(station_line: str) -> str:
    """station_line から駅名を抽出。「」内があればそれ、なければ『〇〇駅』の部分。"""
    if not (station_line and station_line.strip()):
        return ""
    m = re.search(r"[「『]([^」』]+)[」』]", station_line)
    if m:
        return m.group(1).strip()
    m = re.search(r"([^\s]+駅)", station_line)
    if m:
        return m.group(1).strip()
    return (station_line.strip()[:30] or "").strip()


def station_passengers_ok(station_line: str, passengers_map: dict[str, int]) -> bool:
    """駅乗降客数フィルタ。STATION_PASSENGERS_MIN > 0 かつデータがあるときのみチェック。"""
    if STATION_PASSENGERS_MIN <= 0 or not passengers_map:
        return True
    name = station_name_from_line(station_line or "")
    if not name:
        return True
    passengers = passengers_map.get(name) or passengers_map.get(name.replace("駅", "")) or passengers_map.get(name + "駅")
    if passengers is None:
        return True  # データにない駅は通過（取りこぼし防止）
    return passengers >= STATION_PASSENGERS_MIN


# ──────────────────────────── 路線フィルタ ────────────────────────────


def line_ok(station_line: str, *, empty_passes: bool = True) -> bool:
    """路線限定時、最寄り路線がALLOWED_LINE_KEYWORDSのいずれかを含むか。

    empty_passes: station_line が空のとき True を返すか。
      - True: SUUMO系・HOME'S新築（パース失敗時の取りこぼし防止）
      - False: HOME'S中古（空＝路線不明は除外）
    """
    if not ALLOWED_LINE_KEYWORDS:
        return True
    line = (station_line or "").strip()
    if not line:
        return empty_passes
    return any(kw in line for kw in ALLOWED_LINE_KEYWORDS)


# ──────────────────────────── 地域フィルタ ────────────────────────────


def is_tokyo_23_by_address(address: str) -> bool:
    """住所が東京23区のいずれかを含むか（シンプル版）。HOME'S 系で使用。"""
    if not (address and address.strip()):
        return False
    return any(ward in address for ward in TOKYO_23_WARDS)
