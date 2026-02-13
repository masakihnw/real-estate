#!/usr/bin/env python3
"""
geocode_cross_validator.py - 住所・物件名・座標・最寄り駅の相互検証

座標の信頼性を複数のシグナルで相互検証し、問題がある場合は修正を試行する。

検証ロジック:
  1. 駅距離整合性（最も信頼性が高い）
     - station_line から駅名を抽出 → 駅座標を取得（Nominatim + キャッシュ）
     - 物件座標と駅座標の直線距離が walk_min の期待範囲に収まるか検証
  2. 逆ジオコーディング区名一致
     - 座標 → Nominatim 逆引きで区名を取得
     - 住所の区名と一致するか検証
  3. 物件名地名整合性
     - 物件名に含まれる駅名・地名が住所・座標の示す場所と整合するか検証

修正ロジック:
  - 問題検出時は Nominatim で複数クエリパターンを試行
  - 駅座標を制約条件として、走行距離範囲内の候補のみ採用
  - 修正できない場合は geocode_confidence="low" を付与

使い方:
  python scripts/geocode_cross_validator.py results/latest.json [--fix] [--report]
"""

import argparse
import json
import math
import re
import sys
import time
from pathlib import Path
from typing import Optional, Tuple

import requests

# ─── パス ───────────────────────────────────────────
ROOT = Path(__file__).resolve().parent.parent
GEOCODE_CACHE_PATH = ROOT / "data" / "geocode_cache.json"
STATION_CACHE_PATH = ROOT / "data" / "station_cache.json"
REVERSE_CACHE_PATH = ROOT / "data" / "reverse_geocode_cache.json"

# ─── Nominatim 設定 ─────────────────────────────────
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
NOMINATIM_REVERSE_URL = "https://nominatim.openstreetmap.org/reverse"
USER_AGENT = "real-estate-cross-validator/1.0 (personal project)"
RATE_LIMIT_SEC = 1.1  # Nominatim ポリシー: 1 req/sec
_last_request_time = 0.0

# ─── 閾値 ───────────────────────────────────────────
# 不動産業界の徒歩基準: 80m/分
WALK_SPEED_M_PER_MIN = 80

# 駅距離チェック閾値（直線距離 vs walk_min から期待される歩行距離）
# 直線距離 ≈ 歩行距離 × 0.7 が一般的なので、直線距離の上限は歩行距離そのもの
# さらにバッファを持たせる（駅出口差・計測誤差）
STATION_DIST_OK_FACTOR = 1.3     # ≤ 1.3倍: 問題なし
STATION_DIST_WARN_FACTOR = 2.0   # ≤ 2.0倍: 注意
# > 2.0倍: エラー（座標が明らかにおかしい）

# 最低距離閾値（徒歩1-2分の物件でも微小誤差で検知しないように）
STATION_DIST_MIN_M = 200

# 東京23区範囲（geocode.py と同一）
TOKYO_23KU_LAT_RANGE = (35.50, 35.90)
TOKYO_23KU_LON_RANGE = (139.50, 140.00)

# ─── 区の中心座標 ───────────────────────────────────
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

# ─── マンションブランド名プレフィックス（物件名から除去して地名を抽出用）───
_BRAND_PREFIXES = [
    # 三井不動産
    "パークタワー", "パークコート", "パークハウス", "パークシティ",
    "パークホームズ", "パークリュクス", "パークアクシス",
    # 住友不動産
    "シティタワー", "シティハウス", "シティテラス",
    # 東京建物
    "ブリリア", "ブリリアタワー", "ブリリアシティ",
    # 野村不動産
    "プラウド", "プラウドタワー", "プラウドシティ", "オハナ",
    # 三菱地所
    "ザ・パークハウス", "パークハウス",
    # 大京
    "ライオンズ", "ライオンズタワー", "ライオンズマンション",
    # 東急不動産
    "ブランズ", "ブランズタワー",
    # NTT都市開発
    "ウエリス",
    # その他
    "クレストレジデンス", "クレストタワー", "クレストプライム",
    "グランドメゾン", "ザ・タワー", "ヴェレーナ",
    "リビオ", "ルネ", "ルフォン", "サングランデ",
    "レジデンスタワー", "タワーレジデンス",
    "ガーデンズ", "スカイズ", "ベイズ",
]

# ─── ユーティリティ ─────────────────────────────────


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """2点間の距離 (メートル) をHaversine公式で計算。"""
    R = 6_371_000.0  # 地球の半径 (m)
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) *
         math.sin(dlon / 2) ** 2)
    return R * 2 * math.asin(math.sqrt(a))


def _rate_limit():
    """Nominatim のレートリミットを遵守。"""
    global _last_request_time
    elapsed = time.time() - _last_request_time
    if elapsed < RATE_LIMIT_SEC:
        time.sleep(RATE_LIMIT_SEC - elapsed)
    _last_request_time = time.time()


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


def _extract_town(address: str) -> Optional[str]:
    """住所文字列から町名を抽出（区名の後、数字の前）。"""
    m = re.search(r"区(.+?)[０-９0-9一二三四五六七八九十\-－]", address)
    if m:
        return m.group(1).strip()
    # 数字なしの場合は区以降を全部返す
    m = re.search(r"区(.+)$", address)
    return m.group(1).strip() if m else None


def _get_best_address(listing: dict) -> str:
    """物件の最も詳細な住所を返す。

    住まいサーフィンの ss_address（物件概要ページの所在地）があればそちらを優先。
    ss_address は番地レベルまで記載されていることが多く、
    SUUMO の address（丁目レベルまで）よりジオコーディング精度が高い。
    """
    ss_addr = (listing.get("ss_address") or "").strip()
    orig_addr = (listing.get("address") or "").strip()

    if ss_addr:
        # ss_address の区名が orig_address の区名と一致するか確認（誤検索防止）
        ss_ward = _extract_ward(ss_addr)
        orig_ward = _extract_ward(orig_addr)
        if ss_ward and orig_ward and ss_ward == orig_ward:
            return ss_addr
        # 区名が一致しない場合は元住所を使う（住まいサーフィンの検索誤マッチの可能性）
        if ss_ward and orig_ward and ss_ward != orig_ward:
            return orig_addr
        # 区名が取れない場合は ss_address を使う
        return ss_addr

    return orig_addr


# ─── キャッシュ管理 ─────────────────────────────────


def _load_json_cache(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, TypeError, OSError):
        return {}


def _save_json_cache(path: Path, cache: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=0)
    tmp.replace(path)


# ─── 駅座標取得 ─────────────────────────────────────

_station_cache: Optional[dict] = None


def _get_station_cache() -> dict:
    global _station_cache
    if _station_cache is None:
        _station_cache = _load_json_cache(STATION_CACHE_PATH)
    return _station_cache


def _save_station_cache_to_disk() -> None:
    if _station_cache is not None:
        _save_json_cache(STATION_CACHE_PATH, _station_cache)


def _extract_station_name(station_line: str) -> Optional[str]:
    """station_line から駅名を抽出。
    例: 'ＪＲ山手線「品川」徒歩10分' → '品川'
        '東京メトロ日比谷線「三ノ輪」徒歩8分' → '三ノ輪'
    """
    # 全角/半角「」に対応
    m = re.search(r"[「｢](.+?)[」｣]", station_line)
    return m.group(1) if m else None


def _geocode_station(station_name: str) -> Optional[Tuple[float, float]]:
    """駅名を (lat, lon) に変換。キャッシュ優先。

    Nominatim の検索結果は railway/station クラスを優先し、
    不正確な結果（地名一致等）を排除する。
    """
    cache = _get_station_cache()
    if station_name in cache:
        v = cache[station_name]
        if v is None:
            return None
        return tuple(v)

    # Nominatim で検索: 複数クエリパターンを試行
    # "駅名駅 東京" が最も安定するが、有名駅は別の結果を返すことがあるので複数試行
    queries = [
        f"{station_name}駅 東京都",
        f"{station_name}駅 東京",
        f"{station_name} station Tokyo Japan",
    ]
    headers = {"User-Agent": USER_AGENT}

    # 全クエリから候補を収集し、railway/station クラスを最優先
    railway_candidates = []  # railway クラスの結果
    other_candidates = []    # その他の結果

    for query in queries:
        _rate_limit()
        try:
            params = {"q": query, "format": "json", "limit": 5, "countrycodes": "jp"}
            r = requests.get(NOMINATIM_URL, params=params, headers=headers, timeout=10)
            r.raise_for_status()
            data = r.json()
            for result in data:
                lat = float(result["lat"])
                lon = float(result["lon"])
                # 東京23区範囲チェック
                if not (TOKYO_23KU_LAT_RANGE[0] <= lat <= TOKYO_23KU_LAT_RANGE[1] and
                        TOKYO_23KU_LON_RANGE[0] <= lon <= TOKYO_23KU_LON_RANGE[1]):
                    continue
                cls = result.get("class", "")
                typ = result.get("type", "")
                display = result.get("display_name", "")
                osm_type = result.get("osm_type", "")

                # railway クラスまたは station タイプ → 最優先
                if "railway" in cls or typ in ("station", "halt", "platform"):
                    railway_candidates.append((lat, lon, display))
                # display_name に「駅」を含む → 次点
                elif "駅" in display or "Station" in display:
                    other_candidates.append((lat, lon, display))
        except (requests.RequestException, KeyError, ValueError, TypeError):
            continue

    # railway クラスの結果を最優先
    if railway_candidates:
        lat, lon, display = railway_candidates[0]
        cache[station_name] = [lat, lon]
        _save_station_cache_to_disk()
        return (lat, lon)

    # 駅名を含む結果
    if other_candidates:
        lat, lon, display = other_candidates[0]
        cache[station_name] = [lat, lon]
        _save_station_cache_to_disk()
        return (lat, lon)

    # 失敗をキャッシュ（再試行防止）
    cache[station_name] = None
    _save_station_cache_to_disk()
    return None


# ─── 逆ジオコーディング ─────────────────────────────

_reverse_cache: Optional[dict] = None


def _get_reverse_cache() -> dict:
    global _reverse_cache
    if _reverse_cache is None:
        _reverse_cache = _load_json_cache(REVERSE_CACHE_PATH)
    return _reverse_cache


def _save_reverse_cache_to_disk() -> None:
    if _reverse_cache is not None:
        _save_json_cache(REVERSE_CACHE_PATH, _reverse_cache)


def _reverse_geocode(lat: float, lon: float) -> Optional[dict]:
    """座標から住所情報を取得（Nominatim 逆引き）。キャッシュ優先。"""
    cache = _get_reverse_cache()
    key = f"{lat:.6f},{lon:.6f}"
    if key in cache:
        return cache[key]

    _rate_limit()
    headers = {"User-Agent": USER_AGENT}
    try:
        params = {"lat": lat, "lon": lon, "format": "json", "zoom": 16}
        r = requests.get(NOMINATIM_REVERSE_URL, params=params, headers=headers, timeout=10)
        r.raise_for_status()
        data = r.json()
        addr = data.get("address", {})
        result = {
            "display_name": data.get("display_name", ""),
            "city": addr.get("city", ""),
            "suburb": addr.get("suburb", ""),
            "quarter": addr.get("quarter", ""),
            "neighbourhood": addr.get("neighbourhood", ""),
            "city_district": addr.get("city_district", ""),
        }
        cache[key] = result
        _save_reverse_cache_to_disk()
        return result
    except (requests.RequestException, KeyError, ValueError, TypeError):
        return None


def _extract_ward_from_reverse(rev: dict) -> Optional[str]:
    """逆ジオコーディング結果から区名を抽出。"""
    # Nominatim の日本住所は city_district, suburb, city 等にばらける
    for field in ["city_district", "suburb", "city", "quarter"]:
        val = rev.get(field, "")
        if "区" in val:
            m = re.search(r"([一-龥ぁ-んァ-ヴ]+区)", val)
            if m:
                return m.group(1)
    # display_name から探す
    display = rev.get("display_name", "")
    m = re.search(r"([一-龥ぁ-んァ-ヴ]+区)", display)
    return m.group(1) if m else None


# ─── 物件名から地名抽出 ─────────────────────────────


def _extract_location_hints_from_name(name: str) -> list[str]:
    """物件名から地名・駅名のヒントを抽出する。

    戦略:
      1. ブランド名を除去
      2. 残りから日本語地名パターンを抽出
      3. 装飾文字（■□◆★等）や広告文言を除去
    """
    if not name:
        return []

    s = name.strip()

    # 広告文言（【】や◆◆で囲まれたもの）を除去
    s = re.sub(r"【[^】]*】", "", s)
    s = re.sub(r"[■□◆◇★☆●○▲△▼▽♦♠♣♥※]+", "", s)
    s = re.sub(r"[＊＠＃]+", "", s)
    # 「〜」以降の説明を除去
    s = re.sub(r"[〜～].*$", "", s)
    # 「…」以降を除去
    s = re.sub(r"….*$", "", s)
    s = s.strip()

    if not s:
        return []

    # ブランド名を除去
    for brand in sorted(_BRAND_PREFIXES, key=len, reverse=True):
        if s.startswith(brand):
            s = s[len(brand):].strip()
            break
        # 「ザ・」等の接頭辞付き
        for prefix in ["ザ・", "ザ ", "THE ", "The "]:
            if s.startswith(prefix + brand):
                s = s[len(prefix) + len(brand):].strip()
                break

    # 残りの文字列からカタカナ・漢字の地名候補を抽出
    hints = []

    # まず全体を候補に
    if s and len(s) <= 20:
        hints.append(s)

    # スペースや中黒で分割して各パートを候補に
    parts = re.split(r"[\s　・]+", s)
    for part in parts:
        # 装飾や数字のみは除外
        cleaned = re.sub(r"[Ⅰ-ⅩⅰⅱⅲⅳⅴⅵⅶⅷⅸⅹA-Za-zＡ-Ｚａ-ｚ0-9０-９]+$", "", part).strip()
        if cleaned and len(cleaned) >= 2:
            hints.append(cleaned)

    # 重複除去（順序保持）
    seen = set()
    unique = []
    for h in hints:
        if h not in seen:
            seen.add(h)
            unique.append(h)

    return unique


# ─── 検証チェック ───────────────────────────────────


def check_station_distance(listing: dict) -> dict:
    """駅距離整合性チェック。

    Returns:
        {
            "status": "ok" | "warn" | "error" | "skip",
            "message": str,
            "station_name": str or None,
            "station_coords": (lat, lon) or None,
            "expected_max_m": float,
            "actual_m": float,
        }
    """
    station_line = listing.get("station_line", "")
    walk_min = listing.get("walk_min")
    lat = listing.get("latitude")
    lon = listing.get("longitude")

    if not station_line or walk_min is None or lat is None or lon is None:
        return {"status": "skip", "message": "必要なデータが不足"}

    station_name = _extract_station_name(station_line)
    if not station_name:
        return {"status": "skip", "message": "駅名を抽出できず"}

    station_coords = _geocode_station(station_name)
    if not station_coords:
        return {"status": "skip", "message": f"駅 '{station_name}' の座標取得失敗"}

    # 距離計算
    actual_m = _haversine_m(lat, lon, station_coords[0], station_coords[1])
    expected_walk_m = walk_min * WALK_SPEED_M_PER_MIN  # 歩行距離（道なり）
    # 直線距離の上限: 歩行距離 × 係数（直線距離 < 歩行距離 なので余裕を持たせる）
    ok_limit = max(expected_walk_m * STATION_DIST_OK_FACTOR, STATION_DIST_MIN_M)
    warn_limit = max(expected_walk_m * STATION_DIST_WARN_FACTOR, STATION_DIST_MIN_M * 2)

    result = {
        "station_name": station_name,
        "station_coords": list(station_coords),
        "expected_max_m": round(ok_limit),
        "actual_m": round(actual_m),
    }

    if actual_m <= ok_limit:
        result["status"] = "ok"
        result["message"] = f"駅距離OK（{actual_m:.0f}m ≤ {ok_limit:.0f}m）"
    elif actual_m <= warn_limit:
        result["status"] = "warn"
        result["message"] = (f"駅距離やや遠い（{actual_m:.0f}m、上限{ok_limit:.0f}m、"
                             f"徒歩{walk_min}分={expected_walk_m}m）")
    else:
        result["status"] = "error"
        result["message"] = (f"駅距離異常（{actual_m:.0f}m、上限{ok_limit:.0f}m、"
                             f"徒歩{walk_min}分={expected_walk_m}m、{actual_m / expected_walk_m:.1f}倍）")

    return result


def check_reverse_ward(listing: dict) -> dict:
    """逆ジオコーディングによる区名チェック。

    Returns:
        {
            "status": "ok" | "warn" | "error" | "skip",
            "message": str,
            "expected_ward": str or None,
            "actual_ward": str or None,
        }
    """
    lat = listing.get("latitude")
    lon = listing.get("longitude")
    address = _get_best_address(listing)

    if lat is None or lon is None or not address:
        return {"status": "skip", "message": "必要なデータが不足"}

    expected_ward = _extract_ward(address)
    if not expected_ward:
        return {"status": "skip", "message": "住所から区名を抽出できず"}

    rev = _reverse_geocode(lat, lon)
    if not rev:
        return {"status": "skip", "message": "逆ジオコーディング失敗"}

    actual_ward = _extract_ward_from_reverse(rev)
    result = {
        "expected_ward": expected_ward,
        "actual_ward": actual_ward,
        "reverse_display": rev.get("display_name", ""),
    }

    if not actual_ward:
        result["status"] = "warn"
        result["message"] = f"逆引きから区名を抽出できず（{rev.get('display_name', '')}）"
    elif actual_ward == expected_ward:
        result["status"] = "ok"
        result["message"] = f"区名一致（{expected_ward}）"
    else:
        result["status"] = "error"
        result["message"] = f"区名不一致: 住所={expected_ward}, 座標の逆引き={actual_ward}"

    return result


def check_name_location(listing: dict) -> dict:
    """物件名に含まれる地名・駅名の整合性チェック。

    Returns:
        {
            "status": "ok" | "warn" | "error" | "skip",
            "message": str,
            "name_hints": list[str],
            "matched_in_address": bool,
            "matched_station": bool,
        }
    """
    name = listing.get("name", "")
    address = _get_best_address(listing)
    station_line = listing.get("station_line", "")

    if not name or not address:
        return {"status": "skip", "message": "物件名または住所が不足"}

    hints = _extract_location_hints_from_name(name)
    if not hints:
        return {"status": "skip", "message": "物件名から地名ヒントを抽出できず"}

    station_name = _extract_station_name(station_line) if station_line else None
    ward = _extract_ward(address) or ""
    town = _extract_town(address) or ""

    matched_address = False
    matched_station = False

    for hint in hints:
        # 住所中の地名と一致するか
        if hint in address or hint in ward or hint in town:
            matched_address = True
        # 町名がヒントに含まれるか（逆方向も）
        if town and (town in hint or hint in town):
            matched_address = True
        # 駅名と一致するか
        if station_name and (hint == station_name or station_name in hint or hint in station_name):
            matched_station = True

    result = {
        "name_hints": hints,
        "matched_in_address": matched_address,
        "matched_station": matched_station,
    }

    if matched_address or matched_station:
        result["status"] = "ok"
        matches = []
        if matched_address:
            matches.append("住所")
        if matched_station:
            matches.append("駅名")
        result["message"] = f"物件名の地名ヒントが{'/'.join(matches)}と一致"
    else:
        # 物件名に地名ヒントがあるが住所・駅名と一致しない → 注意
        result["status"] = "warn"
        result["message"] = (f"物件名ヒント {hints} が住所 '{address}' や "
                             f"駅名 '{station_name or '?'}' と一致しない")

    return result


# ─── 信頼度判定 ─────────────────────────────────────


def compute_confidence(checks: dict) -> str:
    """各チェック結果から総合信頼度を判定する。

    Returns: "high" | "medium" | "low" | "mismatch"
    """
    station = checks.get("station_distance", {}).get("status", "skip")
    reverse = checks.get("reverse_ward", {}).get("status", "skip")
    name_loc = checks.get("name_location", {}).get("status", "skip")

    # エラーの数をカウント
    errors = sum(1 for s in [station, reverse, name_loc] if s == "error")
    warns = sum(1 for s in [station, reverse, name_loc] if s == "warn")
    oks = sum(1 for s in [station, reverse, name_loc] if s == "ok")

    # 駅距離エラーは最も信頼性が高い指標
    if station == "error":
        if errors >= 2:
            return "mismatch"
        return "low"

    if errors >= 2:
        return "mismatch"
    if errors >= 1:
        return "low"

    if station == "warn":
        return "medium"
    if warns >= 2:
        return "medium"

    if station == "ok":
        if reverse == "ok":
            return "high"
        return "high"  # 駅距離OKだけで十分信頼できる

    # 全てスキップ（データ不足）
    if oks == 0 and errors == 0 and warns == 0:
        return "medium"  # 検証不能

    return "high"


# ─── 座標修正 ───────────────────────────────────────


def _try_nominatim_queries(address: str, name: str, ward: str,
                           ss_address: str = "") -> list[Tuple[float, float, str]]:
    """複数のクエリパターンで Nominatim を試行し、候補座標を返す。

    ss_address（住まいサーフィンの詳細住所）があれば最優先で使用する。
    """
    candidates = []
    headers = {"User-Agent": USER_AGENT}
    queries_tried = set()

    # クエリ生成
    queries = []

    # 0. 住まいサーフィンの詳細住所（最も精度が高い）
    if ss_address:
        s = ss_address.strip()
        if not s.startswith("東京都"):
            s = f"東京都{s}"
        queries.append((f"{s} Japan", "住まいサーフィン住所"))

    # 1. 物件名 + 区名 (有名マンションなら直接ヒット)
    if name and ward:
        clean_name = re.sub(r"[【】■□◆◇★☆●○▲△▼▽♦♠♣♥※…]+", "", name).strip()
        clean_name = re.sub(r"^[＊＠＃]+", "", clean_name).strip()
        if clean_name and len(clean_name) <= 30:
            queries.append((f"{clean_name} {ward} 東京", "物件名+区名"))

    # 2. 住所を構造化して検索（区 + 町名）
    town = _extract_town(address)
    if ward and town:
        queries.append((f"{town} {ward} 東京 Japan", "町名+区名"))
        # 丁目を明示
        m = re.search(r"[０-９0-9一二三四五六七八九]+$", address.strip())
        if m:
            num = m.group()
            # 全角→半角
            num = num.translate(str.maketrans("０１２３４５６７８９", "0123456789"))
            kanji_map = {"一": "1", "二": "2", "三": "3", "四": "4", "五": "5",
                         "六": "6", "七": "7", "八": "8", "九": "9"}
            for k, v in kanji_map.items():
                num = num.replace(k, v)
            queries.append((f"{town}{num}丁目 {ward} 東京都 Japan", "丁目明示"))

    # 3. フル住所そのまま
    if address:
        s = address.strip()
        if not s.startswith("東京都"):
            s = f"東京都{s}"
        queries.append((f"{s} Japan", "フル住所"))

    # 各クエリを実行
    for query, label in queries:
        if query in queries_tried:
            continue
        queries_tried.add(query)

        _rate_limit()
        try:
            params = {"q": query, "format": "json", "limit": 3, "countrycodes": "jp"}
            r = requests.get(NOMINATIM_URL, params=params, headers=headers, timeout=10)
            r.raise_for_status()
            data = r.json()
            for result in data:
                lat = float(result["lat"])
                lon = float(result["lon"])
                if (TOKYO_23KU_LAT_RANGE[0] <= lat <= TOKYO_23KU_LAT_RANGE[1] and
                        TOKYO_23KU_LON_RANGE[0] <= lon <= TOKYO_23KU_LON_RANGE[1]):
                    candidates.append((lat, lon, label))
        except (requests.RequestException, KeyError, ValueError, TypeError):
            continue

    return candidates


def attempt_fix(listing: dict, station_check: dict) -> Optional[Tuple[float, float]]:
    """座標の修正を試行する。

    駅座標を制約条件として使い、駅との距離が妥当な候補のみ採用する。
    ss_address（住まいサーフィンの詳細住所）があれば優先的に使用する。

    Returns: (lat, lon) or None
    """
    address = _get_best_address(listing)
    ss_address = (listing.get("ss_address") or "").strip()
    name = listing.get("name", "")
    ward = _extract_ward(address) or ""
    walk_min = listing.get("walk_min")
    station_coords = station_check.get("station_coords")

    # Nominatim で複数パターン試行（ss_address を最優先）
    candidates = _try_nominatim_queries(address, name, ward, ss_address=ss_address)

    if not candidates:
        # 全クエリ失敗 → 駅座標をフォールバックとして使用
        if station_coords and walk_min:
            print(f"  → 再ジオコーディング失敗。駅座標をフォールバック使用: {station_coords}",
                  file=sys.stderr)
            return tuple(station_coords)
        return None

    # 候補を駅距離でフィルタリング・ソート
    if station_coords and walk_min:
        expected_max_m = max(walk_min * WALK_SPEED_M_PER_MIN * STATION_DIST_OK_FACTOR,
                            STATION_DIST_MIN_M)
        valid = []
        for lat, lon, label in candidates:
            dist = _haversine_m(lat, lon, station_coords[0], station_coords[1])
            # 区名も一致チェック
            if ward:
                # 区の中心からの距離で大まかなチェック
                if ward in _WARD_CENTERS:
                    wc = _WARD_CENTERS[ward]
                    ward_dist = _haversine_m(lat, lon, wc[0], wc[1])
                    if ward_dist > 8000:  # 8km 超えは区外
                        continue
            valid.append((lat, lon, label, dist))

        if valid:
            # 駅距離が妥当な範囲内の候補を優先
            within_range = [(la, lo, lb, d) for la, lo, lb, d in valid if d <= expected_max_m]
            if within_range:
                best = min(within_range, key=lambda x: x[3])
            else:
                # 範囲内候補がなくても、最も近い候補を採用（元よりはマシなはず）
                best = min(valid, key=lambda x: x[3])

            print(f"  → 修正候補: [{best[0]:.6f}, {best[1]:.6f}] "
                  f"(駅距離{best[3]:.0f}m, クエリ={best[2]})", file=sys.stderr)
            return (best[0], best[1])

    # 駅の制約がない場合は最初の候補
    if candidates:
        lat, lon, label = candidates[0]
        print(f"  → 修正候補（駅制約なし）: [{lat:.6f}, {lon:.6f}] (クエリ={label})",
              file=sys.stderr)
        return (lat, lon)

    return None


# ─── メイン処理 ─────────────────────────────────────


def cross_validate_listing(listing: dict, do_reverse: bool = True) -> dict:
    """1件の物件を検証する。

    Returns:
        {
            "confidence": "high" | "medium" | "low" | "mismatch",
            "checks": {
                "station_distance": {...},
                "reverse_ward": {...},
                "name_location": {...},
            },
            "issues": [str, ...],
        }
    """
    checks = {}

    # 1. 駅距離チェック（常に実行）
    checks["station_distance"] = check_station_distance(listing)

    # 2. 逆ジオコーディング区名チェック
    #    駅距離でエラーが出た場合 or 明示的に指定された場合のみ実行（API 節約）
    if do_reverse or checks["station_distance"].get("status") == "error":
        checks["reverse_ward"] = check_reverse_ward(listing)
    else:
        checks["reverse_ward"] = {"status": "skip", "message": "スキップ（駅距離OK）"}

    # 3. 物件名地名チェック（ローカル処理のみ）
    checks["name_location"] = check_name_location(listing)

    # 信頼度判定
    confidence = compute_confidence(checks)
    issues = []
    for key, check in checks.items():
        if check.get("status") in ("error", "warn"):
            issues.append(f"[{key}] {check.get('message', '')}")

    return {
        "confidence": confidence,
        "checks": checks,
        "issues": issues,
    }


def validate_and_fix(listings: list[dict], fix: bool = False,
                     reverse_all: bool = False) -> tuple[list[dict], dict]:
    """全物件を検証し、オプションで修正を試行する。

    Args:
        listings: 物件リスト
        fix: True の場合、問題のある座標の修正を試行
        reverse_all: True の場合、全物件で逆ジオコーディングを実行

    Returns:
        (updated_listings, summary)
    """
    summary = {
        "total": len(listings),
        "with_coords": 0,
        "high": 0, "medium": 0, "low": 0, "mismatch": 0, "no_coords": 0,
        "fixed": 0,
        "issues": [],
    }

    geocode_cache = _load_json_cache(GEOCODE_CACHE_PATH)
    geocode_cache_updated = False

    for i, listing in enumerate(listings):
        name = listing.get("name", "?")
        address = listing.get("address", "?")
        best_address = _get_best_address(listing)
        ss_address = (listing.get("ss_address") or "").strip()
        lat = listing.get("latitude")
        lon = listing.get("longitude")

        if lat is None or lon is None:
            summary["no_coords"] += 1
            listing["geocode_confidence"] = None
            continue

        summary["with_coords"] += 1

        # 検証実行
        result = cross_validate_listing(listing, do_reverse=reverse_all)
        confidence = result["confidence"]
        listing["geocode_confidence"] = confidence

        summary[confidence] += 1

        # 問題がある場合はログ出力
        if confidence in ("low", "mismatch"):
            station_check = result["checks"].get("station_distance", {})
            print(f"\n{'='*60}", file=sys.stderr)
            print(f"⚠ {confidence.upper()}: {name}", file=sys.stderr)
            print(f"  住所: {address}", file=sys.stderr)
            if ss_address and ss_address != address:
                print(f"  住まいサーフィン住所: {ss_address}", file=sys.stderr)
            print(f"  座標: [{lat}, {lon}]", file=sys.stderr)
            for issue in result["issues"]:
                print(f"  {issue}", file=sys.stderr)

            summary["issues"].append({
                "index": i,
                "name": name,
                "address": address,
                "ss_address": ss_address or None,
                "confidence": confidence,
                "issues": result["issues"],
                "coords": [lat, lon],
            })

            # 修正試行
            if fix and confidence in ("low", "mismatch"):
                new_coords = attempt_fix(listing, station_check)
                if new_coords:
                    old_lat, old_lon = lat, lon
                    new_lat, new_lon = new_coords

                    # 逆ジオコーディングで新座標も検証
                    listing_copy = dict(listing)
                    listing_copy["latitude"] = new_lat
                    listing_copy["longitude"] = new_lon
                    new_result = cross_validate_listing(listing_copy, do_reverse=True)
                    new_confidence = new_result["confidence"]

                    if new_confidence in ("high", "medium"):
                        listing["latitude"] = new_lat
                        listing["longitude"] = new_lon
                        listing["geocode_confidence"] = new_confidence
                        listing["geocode_fixed"] = True
                        summary["fixed"] += 1
                        summary[confidence] -= 1
                        summary[new_confidence] += 1

                        # geocode_cache も更新（元住所と ss_address 両方にキャッシュ）
                        addr_key = address.strip()
                        geocode_cache[addr_key] = [new_lat, new_lon]
                        if ss_address and ss_address != address:
                            geocode_cache[ss_address] = [new_lat, new_lon]
                        geocode_cache_updated = True

                        print(f"  ✅ 修正成功: [{old_lat}, {old_lon}] → [{new_lat}, {new_lon}] "
                              f"(信頼度: {confidence} → {new_confidence})", file=sys.stderr)
                    else:
                        print(f"  ❌ 修正候補も検証に失敗（{new_confidence}）。元座標を維持。",
                              file=sys.stderr)
                else:
                    print(f"  ❌ 修正候補なし。元座標を維持。", file=sys.stderr)

        elif confidence == "medium":
            # medium は warn レベルの詳細をログ
            if result["issues"]:
                print(f"\n⚡ MEDIUM: {name} ({address})", file=sys.stderr)
                for issue in result["issues"]:
                    print(f"  {issue}", file=sys.stderr)

    # geocode_cache の保存
    if geocode_cache_updated:
        _save_json_cache(GEOCODE_CACHE_PATH, geocode_cache)
        print(f"\n📦 geocode_cache.json を更新しました", file=sys.stderr)

    return listings, summary


def print_summary(summary: dict) -> None:
    """検証結果のサマリーを出力する。"""
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"📊 ジオコーディング相互検証 サマリー", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)
    print(f"  総物件数:     {summary['total']}", file=sys.stderr)
    print(f"  座標あり:     {summary['with_coords']}", file=sys.stderr)
    print(f"  座標なし:     {summary['no_coords']}", file=sys.stderr)
    print(f"  ─────────────────────", file=sys.stderr)
    print(f"  🟢 HIGH:      {summary['high']}", file=sys.stderr)
    print(f"  🟡 MEDIUM:    {summary['medium']}", file=sys.stderr)
    print(f"  🟠 LOW:       {summary['low']}", file=sys.stderr)
    print(f"  🔴 MISMATCH:  {summary['mismatch']}", file=sys.stderr)
    if summary.get("fixed"):
        print(f"  ✅ 修正済み:   {summary['fixed']}", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)

    if summary["issues"]:
        print(f"\n⚠ 問題のある物件 ({len(summary['issues'])}件):", file=sys.stderr)
        for item in summary["issues"]:
            fixed = " [修正済み]" if item.get("fixed") else ""
            print(f"  [{item['confidence'].upper()}]{fixed} {item['name']}", file=sys.stderr)
            print(f"    住所: {item['address']}", file=sys.stderr)
            print(f"    座標: {item['coords']}", file=sys.stderr)
            for issue in item["issues"]:
                print(f"    {issue}", file=sys.stderr)


# ─── CLI ────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="住所・物件名・座標・最寄り駅の相互検証",
    )
    parser.add_argument("json_path", type=Path, help="物件 JSON ファイルパス")
    parser.add_argument("--fix", action="store_true",
                        help="問題のある座標の修正を試行（geocode_cache も更新）")
    parser.add_argument("--reverse-all", action="store_true",
                        help="全物件で逆ジオコーディング検証を実行（遅い）")
    parser.add_argument("--report", type=Path, default=None,
                        help="検証レポートの出力先（JSON）")
    args = parser.parse_args()

    if not args.json_path.exists():
        print(f"Error: {args.json_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(args.json_path, encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        print(f"Error: {args.json_path} is not a JSON array", file=sys.stderr)
        sys.exit(1)

    print(f"📍 相互検証開始: {len(listings)}件", file=sys.stderr)

    listings, summary = validate_and_fix(
        listings,
        fix=args.fix,
        reverse_all=args.reverse_all,
    )

    print_summary(summary)

    # JSON ファイルを更新（fix モードまたは confidence フィールド付与）
    tmp = args.json_path.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp.replace(args.json_path)
    print(f"\n✅ {args.json_path} を更新しました（geocode_confidence フィールド付与）",
          file=sys.stderr)

    # レポート出力
    if args.report:
        report = {
            "summary": summary,
            "issues": summary["issues"],
        }
        with open(args.report, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        print(f"📄 レポート: {args.report}", file=sys.stderr)

    # mismatch が1件以上あれば exit code 1
    if summary["mismatch"] > 0 or summary["low"] > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
