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


def best_address(listing: dict) -> str:
    """ss_address（住まいサーフィンの番地レベル住所）があれば優先、なければ元の address を返す。"""
    return (listing.get("ss_address") or listing.get("address") or "").strip()


_KNOWN_NAME_TYPOS: list[tuple[str, str]] = [
    ("レジテンス", "レジデンス"),
    ("フォレスコート", "フォレストコート"),
]


def normalize_listing_name(name: str) -> str:
    """同一判定用に物件名を正規化。iOS cleanListingName と同等の装飾除去を行い、
    空白を除いて比較する。"""
    if not name:
        return ""
    import unicodedata
    s = unicodedata.normalize("NFKC", name).strip()
    # 「掲載物件X件」「見学予約」「noimage」は物件名ではない
    if re.match(r"^掲載物件\d+件$", s):
        return ""
    if s in ("見学予約", "noimage"):
        return ""
    # 【...】を除去
    s = re.sub(r"【[^】]*】", "", s)
    # ◆NAME◆ → NAME（先頭◆で囲まれた物件名を抽出）
    m = re.match(r"^◆([^◆]+)◆\s*$", s)
    if m:
        s = m.group(1).strip()
    else:
        # ◆以降をすべて除去（装飾テキスト）
        s = re.sub(r"◆.*$", "", s)
    # ■□ 記号装飾を除去
    s = re.sub(r"[■□]+\s*", "", s)
    # ～以降を除去
    s = re.sub(r"[~～].*$", "", s)
    # 末尾の広告文句
    s = re.sub(r"ペット飼育可能.*$", "", s)
    s = re.sub(r"[♪！!☆★]+$", "", s)
    # 括弧内の別名表記を除去
    s = re.sub(r"[（(][^）)]*[）)]", "", s)
    s = re.sub(r"[（(][^）)]*$", "", s)
    s = s.strip()
    # 棟名の除去
    s = re.sub(r"\s*[A-Za-z]棟$", "", s)
    s = re.sub(r"\s*\d+号棟$", "", s)
    s = re.sub(r"\s*(ノース|サウス|イースト|ウエスト|ウェスト|テラス|セントラル)棟$", "", s)
    # 階数の除去
    s = re.sub(r"\s*\d+[Ff]$", "", s)
    s = re.sub(r"\s*(?:地下)?\d+階.*$", "", s)
    # PROJECT + 説明文の除去
    s = re.sub(r"\s+PROJECT\s+.*$", "", s, flags=re.IGNORECASE)
    # 不動産説明文の除去
    s = re.sub(
        r"\s+(角部屋|リフォーム済み?|フルリフォーム|リノベーション|フルリノベーション"
        r"|大規模修繕.*|ペット(?:可|飼育可|相談)|新規.*リノベ.*"
        r"|南東向|南西向|北東向|北西向|南向き?|北向き?|東向き?|西向き?"
        r"|即入居可?|オーナーチェンジ).*$",
        "", s
    )
    # プレフィックス除去
    s = re.sub(r"^新築マンション\s*", "", s).strip()
    s = re.sub(r"^マンション未入居\s*", "", s).strip()
    s = re.sub(r"^マンション\s*", "", s).strip()
    # 末尾の「閲覧済」を除去
    s = re.sub(r"閲覧済$", "", s).strip()
    # 販売期情報を除去
    s = re.sub(r"\s*[（(]\s*第\d+期\s*\d*次?\s*[）)]\s*$", "", s).strip()
    s = re.sub(r"\s*第\d+期\s*\d*次?\s*$", "", s).strip()
    # 空白をすべて除去（比較用）
    s = re.sub(r"\s+", "", s)
    # 中黒（・）を除去（ザ・レジデンス ↔ ザレジデンス の表記揺れを吸収）
    s = s.replace("・", "")
    # SUUMO 掲載データの既知の誤字を補正
    for typo, correct in _KNOWN_NAME_TYPOS:
        s = s.replace(typo, correct)
    return s


def _extract_station_name(station_line: str) -> str:
    """路線・駅テキストから駅名のみを抽出する。
    例: 'ＪＲ総武線（秋葉原～千葉）「錦糸町」徒歩5分' → '錦糸町'
    """
    if not station_line:
        return ""
    m = re.search(r"[「『]([^」』]+)[」』]", station_line)
    return m.group(1).strip() if m else ""


_NOT_A_NAME_EXACT: set[str] = {
    # 物件の条件・特徴タグ（物件名ではない）
    "ペット可", "ペット相談", "ペット相談可", "ペット飼育可", "ペット可能",
    "即入居可", "即入居", "即引渡し", "即引渡", "即引き渡し",
    "リフォーム済", "リフォーム済み", "リノベーション済", "リノベ済",
    "リノベーション", "フルリノベーション",
    "角部屋", "角住戸", "南向き", "東向き", "西向き", "北向き",
    "最上階", "上層階", "高層階", "低層階",
    "オートロック", "宅配ボックス", "床暖房", "ディスポーザー", "食洗機",
    "管理人常駐", "日勤管理", "24時間有人管理",
    "駐車場あり", "駐車場付", "駐車場付き", "駐輪場あり",
    "新耐震", "旧耐震", "免震", "制震", "耐震",
    "バリアフリー", "フラット35適合",
    "タワーマンション", "タワマン",
    "浴室乾燥機", "追い焚き", "追焚", "バルコニー", "ルーフバルコニー",
    "エレベーター", "エレベータ",
    "分譲賃貸", "賃貸中", "オーナーチェンジ",
    "新築", "未入居", "新築未入居",
    "値下げ", "価格変更", "価格改定",
    "専用庭", "専用庭付", "専用庭付き",
    "メゾネット", "ワイドスパン",
    "2面バルコニー", "3面バルコニー",
}

# 物件の条件・特徴タグを検出するパターン
_NOT_A_NAME_PATTERNS: list[re.Pattern] = [
    re.compile(r"^ペット.*(?:可|相談|OK)$"),
    re.compile(r"^(?:即|即日).*(?:可|可能)$"),
    re.compile(r"^.*リフォーム.*済み?$"),
    re.compile(r"^.*リノベ(?:ーション)?.*済み?$"),
    re.compile(r"^[東西南北]+向き$"),
    re.compile(r"^新築(?:マンション)?$"),
    re.compile(r"^駐[車輪]場.*(?:あり|付き?)$"),
    re.compile(r"^(?:値下げ|価格(?:変更|改定))$"),
    re.compile(r"^(?:フル)?リノベーション$"),
]


def _is_feature_tag(s: str) -> bool:
    """物件の条件・特徴タグであり物件名ではないテキストかどうかを判定する。"""
    if s in _NOT_A_NAME_EXACT:
        return True
    for pat in _NOT_A_NAME_PATTERNS:
        if pat.match(s):
            return True
    return False


def clean_listing_name(name: str) -> str:
    """スクレイピングで取得した物件名のノイズを除去して物件名だけにする。
    - 先頭の「新築マンション」「マンション」「マンション未入居」を除去
    - 末尾の「閲覧済」を除去
    - 「掲載物件X件」のようなテキストは空文字を返す（物件名ではない）
    - 「第X期X次」「( 第X期 X次 )」等の販売期情報を除去
    - 「眺望良好「XXX」」のようなキャッチコピー含みから物件名を抽出
    - 「ペット可」等の物件条件タグは物件名ではない → 空
    """
    if not name:
        return ""
    s = name.strip()
    # 「掲載物件X件」のようなものは物件名ではない → 空
    if re.match(r"^掲載物件\d+件$", s):
        return ""
    # 物件の条件・特徴タグは物件名ではない → 空
    if _is_feature_tag(s):
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
    # プレフィックス除去後に条件タグだけが残った場合も弾く
    if _is_feature_tag(s):
        return ""
    # 路線・駅・徒歩情報しかない場合は物件名ではない → 空
    if re.match(r"^.*線.*駅.*徒歩\s*\d+\s*分.*$", s):
        return ""
    return s


def _normalize_address_for_key(address: str) -> str:
    """住所を丁目レベルに正規化（番・号を除去）。
    iOS normalizeAddressForGrouping と同等。SUUMOの住所表記揺れを吸収する。
    例: '東京都世田谷区上北沢５-13-2' → '東京都世田谷区上北沢5'
        '東京都世田谷区上北沢５-１３－２' → '東京都世田谷区上北沢5'
        '東京都世田谷区上北沢５' → '東京都世田谷区上北沢5'
    """
    import unicodedata
    if not address:
        return ""
    s = unicodedata.normalize("NFKC", address).strip()
    s = re.sub(r"(\d+)\s*[-ー－/／].*$", r"\1", s)
    return s


def identity_key(r: dict) -> tuple:
    """同一物件の識別用キー（価格を除く）。差分検出で「同じ物件で価格だけ変わった → updated」とするために使う。
    station_line は駅名のみに正規化（路線テキストの表記揺れを吸収）。
    address は丁目レベルに正規化（番地以下の精度差を吸収）。
    total_units / walk_min は重複集約の代表レコード変更で変動するため含めない。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        (r.get("layout") or "").strip(),
        r.get("area_m2"),
        _normalize_address_for_key(r.get("address") or ""),
        r.get("built_year"),
        _extract_station_name(r.get("station_line") or ""),
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
    """ユニーク判定用キー（名前・間取り・面積・価格・住所・築年・駅名）。
    全フィールドが一致する物件を同一とみなす。dedupe_listings 側で
    duplicate_count として戸数を集計する。
    station_line は駅名のみに正規化し、walk_min は除外。
    address は丁目レベルに正規化（番地以下の精度差を吸収）。
    SUUMOの路線表記揺れ（ＪＲ総武線 vs ＪＲ総武線快速 等）や
    同一駅での徒歩分数違い（5分 vs 6分）による重複を防ぐ。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        (r.get("layout") or "").strip(),
        r.get("area_m2"),
        r.get("price_man"),
        _normalize_address_for_key(r.get("address") or ""),
        r.get("built_year"),
        _extract_station_name(r.get("station_line") or ""),
    )


def building_key(r: dict) -> tuple:
    """同一マンション（建物）の識別用キー。
    正規化した物件名と区名で判定する（inject_competing_count と同じ粒度）。
    新規物件が「まったく新しいマンション」か「既存マンションの別部屋」かを区別するために使う。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        get_ward_from_address(r.get("address") or ""),
    )


def inject_is_new(
    current: list[dict],
    previous: Optional[list[dict]] = None,
) -> list[dict]:
    """各リスティングに is_new / is_new_building フラグを付与して返す。
    - is_new: 前回スクレイピングに存在しなかった物件
    - is_new_building: is_new かつ同一マンション名の物件が前回データに1件も無い
      （False の場合は「既存マンションの別部屋」）
    previous が None/空の場合は全て is_new=False（初回実行時に全件 New になるのを防ぐ）。
    Slack 通知の差分検出と同じ identity_key ベースの比較を使う。"""
    if not previous:
        for r in current:
            r["is_new"] = False
            r["is_new_building"] = False
        return current
    diff = compare_listings(current, previous)
    new_keys = {identity_key(r) for r in diff["new"]}
    prev_building_keys = {building_key(r) for r in previous}
    for r in current:
        is_new = identity_key(r) in new_keys
        r["is_new"] = is_new
        r["is_new_building"] = is_new and building_key(r) not in prev_building_keys
    return current


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
    """同一行にまとめるキー: 物件名・価格・間取り・住所・築年が同じなら1行にする。
    listing_key との差異（address/built_year 欠落）で異なる建物が誤マージされる問題を修正。"""
    return (
        normalize_listing_name(r.get("name") or ""),
        r.get("price_man"),
        (r.get("layout") or "").strip(),
        (r.get("address") or "").strip(),
        r.get("built_year"),
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


def inject_price_history(
    current: list[dict],
    previous: Optional[list[dict]] = None,
) -> list[dict]:
    """各物件に price_history（価格変動履歴）を付与して返す。
    previous の price_history を継承し、価格が変わった場合に新しいエントリを追加する。
    新規物件は現在の価格で初期化する。"""
    from datetime import date
    today = date.today().isoformat()

    if not previous:
        for r in current:
            price = r.get("price_man")
            r["price_history"] = [{"date": today, "price_man": price}] if price else []
        return current

    prev_by_key: dict[tuple, dict] = {}
    for r in previous:
        k = identity_key(r)
        if k not in prev_by_key:
            prev_by_key[k] = r

    for r in current:
        k = identity_key(r)
        prev = prev_by_key.get(k)
        price = r.get("price_man")

        if prev:
            history = list(prev.get("price_history") or [])
            prev_price = prev.get("price_man")
            if price and price != prev_price:
                history.append({"date": today, "price_man": price})
            elif not history and price:
                history.append({"date": today, "price_man": price})
            r["price_history"] = history
        else:
            r["price_history"] = [{"date": today, "price_man": price}] if price else []

    return current


def inject_first_seen_at(
    current: list[dict],
    previous: Optional[list[dict]] = None,
) -> list[dict]:
    """各物件に first_seen_at（初回掲載検出日）を付与して返す。
    previous に first_seen_at があれば継承し、新規物件は今日の日付で初期化する。"""
    from datetime import date
    today = date.today().isoformat()

    if not previous:
        for r in current:
            if not r.get("first_seen_at"):
                r["first_seen_at"] = today
        return current

    prev_by_key: dict[tuple, dict] = {}
    for r in previous:
        k = identity_key(r)
        if k not in prev_by_key:
            prev_by_key[k] = r

    for r in current:
        k = identity_key(r)
        prev = prev_by_key.get(k)
        if prev and prev.get("first_seen_at"):
            r["first_seen_at"] = prev["first_seen_at"]
        elif not r.get("first_seen_at"):
            r["first_seen_at"] = today

    return current


def inject_competing_count(listings: list[dict]) -> list[dict]:
    """同一マンション（正規化物件名+区名）で何件売り出されているかを competing_listings_count として付与。"""
    from collections import Counter
    groups: Counter = Counter()
    for r in listings:
        name = normalize_listing_name(r.get("name") or "")
        ward = get_ward_from_address(r.get("address") or "")
        if name and ward:
            groups[(name, ward)] += 1

    for r in listings:
        name = normalize_listing_name(r.get("name") or "")
        ward = get_ward_from_address(r.get("address") or "")
        key = (name, ward)
        r["competing_listings_count"] = groups.get(key, 1)

    return listings


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


