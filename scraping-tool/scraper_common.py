"""
スクレイパー共通ユーティリティ。

セッション生成、フィルタ補助関数、WAF 検出など、
suumo_scraper / suumo_shinchiku_scraper / homes_scraper / homes_shinchiku_scraper で
共有する副作用を持つ関数群。
"""

import json
import re
import sys
from functools import lru_cache
from pathlib import Path
from typing import Optional

import requests

from config import (
    USER_AGENT,
    STATION_PASSENGERS_MIN,
    ALLOWED_LINE_KEYWORDS,
    ALLOWED_STATIONS,
    TOKYO_23_WARDS,
)

from logger import get_logger
logger = get_logger(__name__)



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


@lru_cache(maxsize=1)
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


# ──────────────────────────── 路線・駅フィルタ ────────────────────────────


def line_ok(station_line: str, *, empty_passes: bool = True) -> bool:
    """路線・駅フィルタ。ALLOWED_STATIONS（駅名リスト）と ALLOWED_LINE_KEYWORDS の
    両方が設定されている場合はいずれかを満たせば通過。どちらも空なら常に通過。

    empty_passes: station_line が空のとき True を返すか。
      - True: SUUMO系・HOME'S新築（パース失敗時の取りこぼし防止）
      - False: HOME'S中古（空＝路線不明は除外）
    """
    has_station_filter = bool(ALLOWED_STATIONS)
    has_line_filter = bool(ALLOWED_LINE_KEYWORDS)
    if not has_station_filter and not has_line_filter:
        return True
    line = (station_line or "").strip()
    if not line:
        return empty_passes
    if has_station_filter and any(st in line for st in ALLOWED_STATIONS):
        return True
    if has_line_filter and any(kw in line for kw in ALLOWED_LINE_KEYWORDS):
        return True
    return False


# ──────────────────────────── 地域フィルタ ────────────────────────────


_OTHER_PREFECTURES_RE = re.compile(
    r"(?:北海道|青森|岩手|宮城|秋田|山形|福島"
    r"|茨城|栃木|群馬|埼玉|千葉|神奈川"
    r"|新潟|富山|石川|福井|山梨|長野"
    r"|岐阜|静岡|愛知|三重"
    r"|滋賀|京都府|大阪|兵庫|奈良|和歌山"
    r"|鳥取|島根|岡山|広島|山口"
    r"|徳島|香川|愛媛|高知"
    r"|福岡|佐賀|長崎|熊本|大分|宮崎|鹿児島|沖縄)"
)
_OTHER_CITIES = ("大阪市", "名古屋市", "横浜市", "堺市", "川崎市", "さいたま市",
                 "札幌市", "神戸市", "京都市", "福岡市", "北九州市", "浜松市", "相模原市")


def is_tokyo_23_by_address(address: str) -> bool:
    """住所が東京23区のいずれかを含むか。他県の同名区（大阪市北区等）を除外。"""
    if not (address and address.strip()):
        return False
    if _OTHER_PREFECTURES_RE.search(address):
        return False
    if any(city in address for city in _OTHER_CITIES):
        return False
    return any(ward in address for ward in TOKYO_23_WARDS)
