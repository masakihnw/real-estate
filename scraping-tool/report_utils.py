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


def clean_listing_name(name: str) -> str:
    """スクレイピングで取得した物件名のノイズを除去して物件名だけにする。
    - 先頭の「新築マンション」「マンション」「マンション未入居」を除去
    - 末尾の「閲覧済」を除去
    - 「掲載物件X件」のようなテキストは空文字を返す（物件名ではない）
    - 「第X期X次」「( 第X期 X次 )」等の販売期情報を除去
    - 「眺望良好「XXX」」のようなキャッチコピー含みから物件名を抽出
    """
    if not name:
        return ""
    s = name.strip()
    # 「掲載物件X件」のようなものは物件名ではない → 空
    if re.match(r"^掲載物件\d+件$", s):
        return ""
    # 先頭のプレフィックスを除去（順序重要: 長い方から先に試す）
    s = re.sub(r"^新築マンション\s*", "", s).strip()
    s = re.sub(r"^マンション未入居\s*", "", s).strip()
    s = re.sub(r"^マンション\s*", "", s).strip()
    # 末尾の「閲覧済」を除去
    s = re.sub(r"閲覧済$", "", s).strip()
    # 販売期情報を除去: 「第1期1次」「　第1期1次」「( 第2期 2次 )」
    s = re.sub(r"\s*[（(]\s*第\d+期\s*\d*次?\s*[）)]\s*$", "", s).strip()
    s = re.sub(r"\s*第\d+期\s*\d*次?\s*$", "", s).strip()
    # キャッチコピー含みの物件名を抽出: 「眺望良好「XXX」」→「XXX」
    # ただし、物件名自体が「」で囲まれている場合のみ
    m = re.search(r"[「『]([^」』]{3,})[」』]", s)
    if m and s != m.group(1):
        # 「」の外側に余計なテキスト（キャッチコピー等）がある場合
        prefix = s[:m.start()].strip()
        suffix = s[m.end():].strip()
        # 外側テキストが路線名や駅名でなければ、括弧内を物件名とする
        if prefix and "線" not in prefix and "駅" not in prefix:
            s = m.group(1).strip()
    # 路線・駅・徒歩情報しかない場合は物件名ではない → 空
    if re.match(r"^.*線.*駅.*徒歩\s*\d+\s*分.*$", s):
        return ""
    return s


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


# 差分検出で比較するプロパティキー。いずれかが前回と異なれば「updated」とする
PROPERTY_CHANGE_KEYS = (
    "name", "url", "address", "price_man", "area_m2", "walk_min",
    "floor_position", "ownership", "built_year", "total_units",
    "station_line", "layout", "floor_total", "list_ward_roman",
)


def _norm_prop(v: Any) -> Any:
    """プロパティ比較用。None と空文字を揃え、数値は int/float を統一。"""
    if v is None:
        return None
    if isinstance(v, str):
        s = v.strip()
        return s if s else None
    if isinstance(v, float) and v == int(v):
        return int(v)
    return v


def listing_has_property_changes(curr: dict, prev: dict) -> bool:
    """差分検出で比較するプロパティのいずれかが curr と prev で異なれば True。"""
    for key in PROPERTY_CHANGE_KEYS:
        if _norm_prop(curr.get(key)) != _norm_prop(prev.get(key)):
            return True
    return False


def listing_key(r: dict) -> tuple:
    """ユニーク判定用キー（名前・間取り・面積・価格・住所・築年・路線・徒歩）。
    全フィールドが一致する物件を同一とみなす。dedupe_listings 側で
    duplicate_count として戸数を集計する。"""
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
    """前回結果と比較して差分を検出。同一物件は identity_key で判定し、価格や総戸数などのプロパティ変更があれば updated とする。"""
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
        elif listing_has_property_changes(curr, prev):
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


def format_floor(
    floor_position: Optional[int],
    floor_total: Optional[int],
    floor_structure: Optional[str] = None,
) -> str:
    """所在階/構造・階建 の形式で表示。例: 12階/RC13階地下1階建。floor_structure があればそれを使い、なければ N階/M階建。"""
    pos = floor_position is not None and floor_position >= 0
    tot = floor_total is not None and floor_total >= 1
    structure = (floor_structure or "").strip()
    if pos and structure:
        return f"{floor_position}階/{structure}"
    if pos and tot:
        return f"{floor_position}階/{floor_total}階建"
    if pos:
        return f"{floor_position}階"
    if structure:
        return structure
    if tot:
        return f"{floor_total}階建"
    return "階:-"


def format_ownership(ownership: Optional[str]) -> str:
    """所有権/借地権/底地権等を表示。一般定期借地権は「一般定期借地権（賃借権）」のみ表示。未取得時は「権利:不明」。"""
    if not ownership or not (ownership or "").strip():
        return "権利:不明"
    s = (ownership or "").strip()
    if "一般定期借地権（賃借権）" in s:
        return "一般定期借地権（賃借権）"
    return s


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


def google_maps_url(query: str) -> str:
    """検索クエリ（物件名・住所など）から Google Map の検索URLを返す。空の場合は空文字。"""
    if not query or not query.strip():
        return ""
    return f"https://www.google.com/maps/search/?api=1&query={quote(query.strip())}"


def google_maps_link(query: str) -> str:
    """検索クエリ（物件名・住所など）から Google Map のハイパーリンク Markdown を返す。"""
    url = google_maps_url(query)
    if not url:
        return "-"
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


