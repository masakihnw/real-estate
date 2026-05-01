"""
10年住み替え前提・中古マンション購入条件に基づくフィルタ設定。

【条件の参照】
- 詳細・厳格化の考え方: ../docs/10year-index-mansion-conditions-draft.md
- 初回ヒアリングの希望条件: ../docs/initial-consultation.md

【対象エリア】東京23区（路線・駅の指定なし）。
駅徒歩10分以内。築20年以内・専有55㎡以上（上限なし）・総戸数30戸以上。価格9,000万〜1億1,500万円。
"""

from __future__ import annotations

import datetime
import json
import threading
from pathlib import Path
from typing import Any, TypedDict, cast

# グローバル設定の変更を保護するロック（複数スレッドが同時に apply_runtime_overrides を呼ぶ場合）
_config_lock = threading.Lock()

# 検索地域: 東京23区以内
AREA_LABEL = "東京23区"
# 23区の区名（住所フィルタ用。SUUMO 東京都一覧から23区のみ残す）
TOKYO_23_WARDS = (
    "千代田区", "中央区", "港区", "新宿区", "文京区", "台東区", "墨田区", "江東区",
    "品川区", "目黒区", "大田区", "世田谷区", "渋谷区", "中野区", "杉並区", "豊島区",
    "北区", "荒川区", "板橋区", "練馬区", "足立区", "葛飾区", "江戸川区",
)
# SUUMO URL で東京23区以外と判定する都県パス（/ms/chuko/kanagawa/ 等）
NON_TOKYO_23_URL_PATHS = ("/kanagawa/", "/chiba/", "/saitama/", "/ibaraki/", "/tochigi/", "/gunma/")

_METADATA_PATH = Path(__file__).resolve().parents[1] / "real-estate-ios" / "RealEstateApp" / "ScrapingConfigMetadata.json"


class _IntRange(TypedDict):
    min: int
    max: int


class _BuiltYearConstraint(TypedDict):
    min: int
    maxOffsetFromCurrentYear: int


class _Defaults(TypedDict):
    priceMinMan: int
    priceMaxMan: int
    areaMinM2: int
    areaMaxM2: int | None
    walkMinMax: int
    builtYearMinOffsetYears: int
    totalUnitsMin: int
    layoutPrefixOk: list[str]
    allowedLineKeywords: list[str]
    allowedStations: list[str]


class _Constraints(TypedDict):
    priceMinMan: _IntRange
    priceMaxMan: _IntRange
    areaMinM2: _IntRange
    areaMaxM2: _IntRange
    walkMinMax: _IntRange
    totalUnitsMin: _IntRange
    builtYearMinOffsetYears: _IntRange
    builtYearMin: _BuiltYearConstraint


class _LayoutOption(TypedDict):
    prefix: str
    label: str


class _StationGroup(TypedDict):
    line: str
    stations: list[str]


class _MetadataDoc(TypedDict):
    schemaVersion: int
    defaults: _Defaults
    constraints: _Constraints
    layoutOptions: list[_LayoutOption]
    lineKeywords: list[str]
    stationGroups: list[_StationGroup]


def _fallback_metadata() -> _MetadataDoc:
    return cast(_MetadataDoc, {
        "schemaVersion": 1,
        "defaults": {
            "priceMinMan": 9000,
            "priceMaxMan": 11500,
            "areaMinM2": 55,
            "areaMaxM2": None,
            "walkMinMax": 10,
            "builtYearMinOffsetYears": 20,
            "totalUnitsMin": 30,
            "layoutPrefixOk": ["2", "3"],
            "allowedLineKeywords": [],
            "allowedStations": [],
        },
        "constraints": {
            "priceMinMan": {"min": 0, "max": 30000},
            "priceMaxMan": {"min": 0, "max": 30000},
            "areaMinM2": {"min": 1, "max": 300},
            "areaMaxM2": {"min": 1, "max": 300},
            "walkMinMax": {"min": 1, "max": 20},
            "totalUnitsMin": {"min": 1, "max": 10000},
            "builtYearMinOffsetYears": {"min": 1, "max": 50},
            "builtYearMin": {"min": 1970, "maxOffsetFromCurrentYear": 0},
        },
        "layoutOptions": [
            {"prefix": "1", "label": "1LDK系"},
            {"prefix": "2", "label": "2LDK系"},
            {"prefix": "3", "label": "3LDK系"},
            {"prefix": "4", "label": "4LDK系"},
            {"prefix": "5+", "label": "5LDK以上"},
        ],
        "lineKeywords": [
            "ＪＲ", "東京メトロ", "都営",
            "東急", "京急", "京成", "東武", "西武", "小田急", "京王", "相鉄",
            "つくばエクスプレス", "モノレール", "舎人ライナー",
            "ゆりかもめ", "りんかい",
        ],
        "stationGroups": [],
    })


def _load_metadata() -> _MetadataDoc:
    base = _fallback_metadata()
    if not _METADATA_PATH.exists():
        return base
    try:
        loaded = json.loads(_METADATA_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return base
    if not isinstance(loaded, dict):
        return base
    merged: dict[str, Any] = dict(base)
    for key in ("schemaVersion", "defaults", "constraints", "layoutOptions", "lineKeywords", "stationGroups"):
        if key in loaded:
            merged[key] = loaded[key]
    return cast(_MetadataDoc, merged)


def _to_int(v: Any, default: int) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _to_optional_int(v: Any) -> int | None:
    if v is None:
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _to_str_list(v: Any) -> list[str]:
    if not isinstance(v, list):
        return []
    out: list[str] = []
    seen: set[str] = set()
    for item in v:
        s = str(item).strip()
        if not s or s in seen:
            continue
        out.append(s)
        seen.add(s)
    return out


SCRAPING_CONFIG_METADATA = _load_metadata()
_DEFAULTS = SCRAPING_CONFIG_METADATA.get("defaults", {}) if isinstance(SCRAPING_CONFIG_METADATA.get("defaults"), dict) else {}
_CONSTRAINTS = SCRAPING_CONFIG_METADATA.get("constraints", {}) if isinstance(SCRAPING_CONFIG_METADATA.get("constraints"), dict) else {}
_THIS_YEAR = datetime.date.today().year
_OFFSET_CONSTRAINT = _CONSTRAINTS.get("builtYearMinOffsetYears", {})
_BUILT_OFFSET_MIN = _to_int(_OFFSET_CONSTRAINT.get("min"), 1) if isinstance(_OFFSET_CONSTRAINT, dict) else 1
_BUILT_OFFSET_MAX = _to_int(_OFFSET_CONSTRAINT.get("max"), 50) if isinstance(_OFFSET_CONSTRAINT, dict) else 50
_BUILT_OFFSET = min(max(_BUILT_OFFSET_MIN, _to_int(_DEFAULTS.get("builtYearMinOffsetYears"), 20)), _BUILT_OFFSET_MAX)

# 価格帯（万円）
PRICE_MIN_MAN = _to_int(_DEFAULTS.get("priceMinMan"), 9000)
PRICE_MAX_MAN = _to_int(_DEFAULTS.get("priceMaxMan"), 11500)

# 専有面積（㎡）
AREA_MIN_M2 = _to_int(_DEFAULTS.get("areaMinM2"), 55)
AREA_MAX_M2 = _to_optional_int(_DEFAULTS.get("areaMaxM2"))

# 間取り
LAYOUT_PREFIX_OK = tuple(_to_str_list(_DEFAULTS.get("layoutPrefixOk")) or ["2", "3"])

# 築年
BUILT_YEAR_MIN = _THIS_YEAR - _BUILT_OFFSET

# 駅徒歩
WALK_MIN_MAX = _to_int(_DEFAULTS.get("walkMinMax"), 10)

# 総戸数
TOTAL_UNITS_MIN = _to_int(_DEFAULTS.get("totalUnitsMin"), 30)

# 路線キーワード / 駅名
ALLOWED_LINE_KEYWORDS = tuple(_to_str_list(_DEFAULTS.get("allowedLineKeywords")))
ALLOWED_STATIONS = tuple(_to_str_list(_DEFAULTS.get("allowedStations")))

# 駅乗降客数: 1日あたりこの値以上の駅のみ通過。0 のときはフィルタなし。
# data/station_passengers.json を scripts/fetch_station_passengers.py で1回取得してから有効になる。
STATION_PASSENGERS_MIN = 0

# SUUMO 23区のローマ字コード（区ごと一覧取得・23区判定で使用）
SUUMO_23_WARD_ROMAN = (
    "chiyoda", "chuo", "minato", "shinjuku", "bunkyo", "shibuya",
    "taito", "sumida", "koto", "arakawa", "adachi", "katsushika", "edogawa",
    "shinagawa", "meguro", "ota", "setagaya",
    "nakano", "suginami", "nerima",
    "toshima", "kita", "itabashi",
)

# SUUMO JJ012FC001 URL 用の区コード（JIS市区町村コード）
# /jj/bukken/ichiran/JJ012FC001/?sc=XXXXX でサーバーサイド価格フィルタを利用する際に使用
SUUMO_23_WARD_SC_CODES: dict[str, str] = {
    "chiyoda": "13101", "chuo": "13102", "minato": "13103",
    "shinjuku": "13104", "bunkyo": "13105", "taito": "13106",
    "sumida": "13107", "koto": "13108", "shinagawa": "13109",
    "meguro": "13110", "ota": "13111", "setagaya": "13112",
    "shibuya": "13113", "nakano": "13114", "suginami": "13115",
    "toshima": "13116", "kita": "13117", "arakawa": "13118",
    "itabashi": "13119", "nerima": "13120", "adachi": "13121",
    "katsushika": "13122", "edogawa": "13123",
}

# リクエスト間隔（秒）: 負荷軽減のため
REQUEST_DELAY_SEC = 2
# HOME'S 専用のリクエスト間隔（秒）: AWS WAF ボット検知対策のため長めに設定
HOMES_REQUEST_DELAY_SEC = 5
# サイト別リクエスト間隔（秒）
ATHOME_REQUEST_DELAY_SEC = 5
REHOUSE_REQUEST_DELAY_SEC = 3
NOMUCOM_REQUEST_DELAY_SEC = 3
STEPON_REQUEST_DELAY_SEC = 3
LIVABLE_REQUEST_DELAY_SEC = 3

# リクエストタイムアウト（秒）: 全ページ取得時は回数が増えるため余裕を持たせる
REQUEST_TIMEOUT_SEC = 60
# タイムアウト・接続エラー時のリトライ回数
REQUEST_RETRIES = 3

# User-Agent: 明示的にブラウザ相当を指定
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def _normalize_runtime_config() -> None:
    global PRICE_MIN_MAN, PRICE_MAX_MAN, AREA_MIN_M2, AREA_MAX_M2, WALK_MIN_MAX, BUILT_YEAR_MIN, TOTAL_UNITS_MIN
    global LAYOUT_PREFIX_OK, ALLOWED_LINE_KEYWORDS, ALLOWED_STATIONS

    price_min_c = _CONSTRAINTS.get("priceMinMan", {})
    price_max_c = _CONSTRAINTS.get("priceMaxMan", {})
    area_min_c = _CONSTRAINTS.get("areaMinM2", {})
    area_max_c = _CONSTRAINTS.get("areaMaxM2", {})
    walk_c = _CONSTRAINTS.get("walkMinMax", {})
    units_c = _CONSTRAINTS.get("totalUnitsMin", {})
    built_c = _CONSTRAINTS.get("builtYearMin", {})

    price_min_min = _to_int(price_min_c.get("min"), 0) if isinstance(price_min_c, dict) else 0
    price_min_max = _to_int(price_min_c.get("max"), 30000) if isinstance(price_min_c, dict) else 30000
    price_max_min = _to_int(price_max_c.get("min"), 0) if isinstance(price_max_c, dict) else 0
    price_max_max = _to_int(price_max_c.get("max"), 30000) if isinstance(price_max_c, dict) else 30000

    PRICE_MIN_MAN = min(max(price_min_min, int(PRICE_MIN_MAN)), price_min_max)
    PRICE_MAX_MAN = min(max(price_max_min, int(PRICE_MAX_MAN)), price_max_max)
    if PRICE_MIN_MAN > PRICE_MAX_MAN:
        PRICE_MIN_MAN, PRICE_MAX_MAN = PRICE_MAX_MAN, PRICE_MIN_MAN

    area_min_min = _to_int(area_min_c.get("min"), 1) if isinstance(area_min_c, dict) else 1
    area_min_max = _to_int(area_min_c.get("max"), 300) if isinstance(area_min_c, dict) else 300
    area_max_min = _to_int(area_max_c.get("min"), 1) if isinstance(area_max_c, dict) else 1
    area_max_max = _to_int(area_max_c.get("max"), 300) if isinstance(area_max_c, dict) else 300
    AREA_MIN_M2 = min(max(area_min_min, int(AREA_MIN_M2)), area_min_max)
    AREA_MAX_M2 = min(max(area_max_min, int(AREA_MAX_M2)), area_max_max) if AREA_MAX_M2 is not None else None
    if AREA_MAX_M2 is not None and AREA_MAX_M2 < AREA_MIN_M2:
        AREA_MAX_M2 = None

    walk_min = _to_int(walk_c.get("min"), 1) if isinstance(walk_c, dict) else 1
    walk_max = _to_int(walk_c.get("max"), 20) if isinstance(walk_c, dict) else 20
    WALK_MIN_MAX = min(max(walk_min, int(WALK_MIN_MAX)), walk_max)

    built_min = _to_int(built_c.get("min"), 1970) if isinstance(built_c, dict) else 1970
    built_max_offset = _to_int(built_c.get("maxOffsetFromCurrentYear"), 0) if isinstance(built_c, dict) else 0
    built_max = datetime.date.today().year - max(0, built_max_offset)
    BUILT_YEAR_MIN = min(max(built_min, int(BUILT_YEAR_MIN)), built_max)

    units_min = _to_int(units_c.get("min"), 1) if isinstance(units_c, dict) else 1
    units_max = _to_int(units_c.get("max"), 10000) if isinstance(units_c, dict) else 10000
    TOTAL_UNITS_MIN = min(max(units_min, int(TOTAL_UNITS_MIN)), units_max)

    if not LAYOUT_PREFIX_OK:
        LAYOUT_PREFIX_OK = ("2", "3")
    else:
        LAYOUT_PREFIX_OK = tuple(dict.fromkeys(str(x).strip() for x in LAYOUT_PREFIX_OK if str(x).strip()))

    ALLOWED_LINE_KEYWORDS = tuple(dict.fromkeys(str(x).strip() for x in ALLOWED_LINE_KEYWORDS if str(x).strip()))
    ALLOWED_STATIONS = tuple(dict.fromkeys(str(x).strip() for x in ALLOWED_STATIONS if str(x).strip()))


def apply_runtime_overrides(data: dict[str, Any]) -> bool:
    """
    Firestore など外部設定を runtime 反映する。
    1つでも適用されたら True を返す。
    スレッドセーフ: 同時呼び出しは _config_lock で排他制御する。
    """
    with _config_lock:
        return _apply_runtime_overrides_locked(data)


def _apply_runtime_overrides_locked(data: dict[str, Any]) -> bool:
    """ロック取得済みの状態で呼ぶ内部実装。"""
    global PRICE_MIN_MAN, PRICE_MAX_MAN, AREA_MIN_M2, AREA_MAX_M2, WALK_MIN_MAX, BUILT_YEAR_MIN, TOTAL_UNITS_MIN
    global LAYOUT_PREFIX_OK, ALLOWED_LINE_KEYWORDS, ALLOWED_STATIONS

    applied = False

    if "priceMinMan" in data and data["priceMinMan"] is not None:
        PRICE_MIN_MAN = int(data["priceMinMan"])
        applied = True
    if "priceMaxMan" in data and data["priceMaxMan"] is not None:
        PRICE_MAX_MAN = int(data["priceMaxMan"])
        applied = True
    if "areaMinM2" in data and data["areaMinM2"] is not None:
        AREA_MIN_M2 = int(data["areaMinM2"])
        applied = True
    if "areaMaxM2" in data:
        AREA_MAX_M2 = int(data["areaMaxM2"]) if data["areaMaxM2"] is not None else None
        applied = True
    if "walkMinMax" in data and data["walkMinMax"] is not None:
        WALK_MIN_MAX = int(data["walkMinMax"])
        applied = True
    if "builtYearMin" in data and data["builtYearMin"] is not None:
        try:
            BUILT_YEAR_MIN = int(data["builtYearMin"])
            applied = True
        except (TypeError, ValueError):
            pass
    if "totalUnitsMin" in data and data["totalUnitsMin"] is not None:
        TOTAL_UNITS_MIN = int(data["totalUnitsMin"])
        applied = True
    if "layoutPrefixOk" in data and isinstance(data["layoutPrefixOk"], list):
        LAYOUT_PREFIX_OK = tuple(str(x) for x in data["layoutPrefixOk"])
        applied = True
    if "allowedLineKeywords" in data and isinstance(data["allowedLineKeywords"], list):
        ALLOWED_LINE_KEYWORDS = tuple(str(x) for x in data["allowedLineKeywords"])
        applied = True
    if "allowedStations" in data and isinstance(data["allowedStations"], list):
        ALLOWED_STATIONS = tuple(str(x) for x in data["allowedStations"])
        applied = True

    _normalize_runtime_config()
    return applied


def get_config() -> dict[str, Any]:
    """
    現在のスクレイピング設定をスナップショットとして返す。

    グローバル変数を直接参照する代わりにこの関数を使うことで、
    将来的に設定をデータクラスに移行しても呼び出し側を変えずに済む。

    Returns:
        設定値を持つ dict（読み取り専用として扱うこと）
    """
    with _config_lock:
        return {
            "price_min_man": PRICE_MIN_MAN,
            "price_max_man": PRICE_MAX_MAN,
            "area_min_m2": AREA_MIN_M2,
            "area_max_m2": AREA_MAX_M2,
            "layout_prefix_ok": LAYOUT_PREFIX_OK,
            "built_year_min": BUILT_YEAR_MIN,
            "walk_min_max": WALK_MIN_MAX,
            "total_units_min": TOTAL_UNITS_MIN,
            "allowed_line_keywords": ALLOWED_LINE_KEYWORDS,
            "allowed_stations": ALLOWED_STATIONS,
            "station_passengers_min": STATION_PASSENGERS_MIN,
            "request_delay_sec": REQUEST_DELAY_SEC,
            "homes_request_delay_sec": HOMES_REQUEST_DELAY_SEC,
            "request_timeout_sec": REQUEST_TIMEOUT_SEC,
            "request_retries": REQUEST_RETRIES,
            "user_agent": USER_AGENT,
        }


_normalize_runtime_config()
