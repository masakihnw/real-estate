#!/usr/bin/env python3
"""
レポート・Slack通知で共有するフォーマット・比較ロジック。
generate_report.py と slack_notify.py の重複を避けるため共通化。
main.py / check_changes.py からも listing_key や load_json を利用可能。
"""

import json
import re
from pathlib import Path
from typing import Any, Optional
from urllib.parse import quote

try:
    from config import TOKYO_23_WARDS
except ImportError:
    TOKYO_23_WARDS = (
        "千代田区", "中央区", "港区", "新宿区", "文京区", "台東区", "墨田区", "江東区",
        "品川区", "目黒区", "大田区", "世田谷区", "渋谷区", "中野区", "杉並区", "豊島区",
        "北区", "荒川区", "板橋区", "練馬区", "足立区", "葛飾区", "江戸川区",
    )


def normalize_listing_name(name: str) -> str:
    """同一判定用に物件名を正規化。全角・半角スペース等を除いて比較する。"""
    if not name:
        return ""
    s = (name or "").strip()
    return re.sub(r"\s+", "", s)


def identity_key(r: dict) -> tuple:
    """同一物件の識別用キー（価格を除く）。差分検出で「同じ物件で価格だけ変わった → updated」とするために使う。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        (r.get("layout") or "").strip(),
        r.get("area_m2"),
        (r.get("address") or "").strip(),
        r.get("built_year"),
        (r.get("station_line") or "").strip(),
        r.get("walk_min"),
    )


def listing_key(r: dict) -> tuple:
    """完全一致判定用のキー（価格含む）。重複除去（dedupe）等で「名前・間取り・広さ・価格・住所・築年・駅徒歩が全て一致」を同一とする。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        (r.get("layout") or "").strip(),
        r.get("area_m2"),
        r.get("price_man"),
        (r.get("address") or "").strip(),
        r.get("built_year"),
        (r.get("station_line") or "").strip(),
        r.get("walk_min"),
    )


def compare_listings(current: list[dict], previous: Optional[list[dict]] = None) -> dict[str, Any]:
    """前回結果と比較して差分を検出。同一物件は identity_key（価格を除く）で判定し、価格差分は updated とする。"""
    if not previous:
        return {
            "new": current,
            "updated": [],
            "removed": [],
            "unchanged": [],
        }

    current_by_key: dict[tuple, dict] = {}
    for r in current:
        k = identity_key(r)
        if k not in current_by_key:
            current_by_key[k] = r
    previous_by_key: dict[tuple, dict] = {}
    for r in previous:
        k = identity_key(r)
        if k not in previous_by_key:
            previous_by_key[k] = r

    new = []
    updated = []
    unchanged = []
    removed = []

    for k, curr in current_by_key.items():
        prev = previous_by_key.get(k)
        if not prev:
            new.append(curr)
        elif curr.get("price_man") != prev.get("price_man"):
            updated.append({"current": curr, "previous": prev})
        else:
            unchanged.append(curr)

    for k, prev in previous_by_key.items():
        if k not in current_by_key:
            removed.append(prev)

    return {
        "new": new,
        "updated": updated,
        "removed": removed,
        "unchanged": unchanged,
    }


def row_merge_key(r: dict) -> tuple:
    """同一行にまとめるキー: 物件名・価格・間取りが同じなら1行にする。名前は正規化して全角スペース差を無視。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        r.get("price_man"),
        (r.get("layout") or "").strip(),
    )


def format_price(price_man: Optional[int]) -> str:
    """価格を読みやすい形式に。"""
    if price_man is None:
        return "-"
    if price_man >= 10000:
        oku = price_man // 10000
        man = price_man % 10000
        if man == 0:
            return f"{oku}億円"
        return f"{oku}億{man}万円"
    return f"{price_man}万円"


def format_area(area_m2: Optional[float]) -> str:
    """専有面積を読みやすい形式に。"""
    if area_m2 is None:
        return "-"
    return f"{area_m2:.1f}㎡"


def format_walk(walk_min: Optional[int]) -> str:
    """徒歩分数を読みやすい形式に。"""
    if walk_min is None:
        return "-"
    return f"徒歩{walk_min}分"


def format_total_units(total_units: Optional[int]) -> str:
    """総戸数を読みやすい形式に。未取得時は「戸数:不明」（列名が分かるように）。"""
    if total_units is None:
        return "戸数:不明"
    return f"{total_units}戸"


def format_floor(floor_position: Optional[int], floor_total: Optional[int]) -> str:
    """何階 / 何階建て を読みやすい形式に。未取得時は「階:-」（列名が分かるように）。"""
    pos = floor_position is not None and floor_position >= 0
    tot = floor_total is not None and floor_total >= 1
    if pos and tot:
        return f"{floor_position}階/{floor_total}階建"
    if pos:
        return f"{floor_position}階"
    if tot:
        return f"{floor_total}階建"
    return "階:-"


def get_ward_from_address(address: str) -> str:
    """住所から23区の区名を取得。見つからなければ空文字。"""
    if not address:
        return ""
    for w in TOKYO_23_WARDS:
        if w in address:
            return w
    return ""


def format_address_from_ward(address: str) -> str:
    """住所から「区」以降を返す。例: 東京都目黒区五本木１ → 目黒区五本木１。"""
    if not address or not address.strip():
        return "-"
    s = address.strip()
    if s.startswith("東京都"):
        s = s[3:].lstrip()
    for w in TOKYO_23_WARDS:
        if w in s:
            idx = s.find(w)
            return s[idx:].strip() or "-"
    return s[:30] or "-"


def google_maps_link(address: str) -> str:
    """住所から Google Map のハイパーリンク Markdown を返す。"""
    if not address or not address.strip():
        return "-"
    q = quote(address.strip())
    url = f"https://www.google.com/maps/search/?api=1&query={q}"
    return f"[Google Map]({url})"


def get_station_group(station_line: str) -> str:
    """路線・駅文字列から最寄駅グループ用のラベルを取得。『』内があればそれ、なければ先頭25文字。"""
    if not station_line or not station_line.strip():
        return "(駅情報なし)"
    m = re.search(r"[「『]([^」』]+)[」』]", station_line)
    if m:
        return m.group(1).strip()
    return (station_line.strip()[:25] or "(駅情報なし)")


def load_json(
    path: Path,
    *,
    missing_ok: bool = False,
    default: Optional[list[dict[str, Any]]] = None,
) -> list[dict[str, Any]]:
    """JSONファイルを読み込む。missing_ok=True かつ path が無い場合は default を返す（未指定時は []）。"""
    if missing_ok and not path.exists():
        return default if default is not None else []
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


