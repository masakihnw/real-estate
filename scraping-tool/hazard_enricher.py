#!/usr/bin/env python3
"""
物件の座標をもとにハザード情報を付与する enricher。

ハザード判定方法:
  1. GSI ハザードマップタイル: 物件座標に対応するタイルピクセルの色を確認し、
     非透明ならハザード該当と判定（洪水、土砂、高潮、津波、液状化、内水浸水）。
  2. 東京都地域危険度 GeoJSON: 物件座標が GeoJSON ポリゴン内にあるか判定し、
     建物倒壊・火災・総合危険度のランク (1-5) を取得。

使い方:
  python3 hazard_enricher.py --input results/latest.json --output results/latest.json
  python3 hazard_enricher.py --input results/latest_shinchiku.json --output results/latest_shinchiku.json
"""

from __future__ import annotations

import argparse
import io
import json
import math
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Lock
from typing import Any, Optional

import requests

# ────────────────────────────────────────────────────────
# GSI ハザードマップタイル設定
# ────────────────────────────────────────────────────────

# タイルチェック用ズームレベル（高いほど解像度が良いが、タイル数が増える）
TILE_ZOOM = 17

# GSI ハザードタイル定義: key → (URL テンプレート, ラベル)
GSI_HAZARD_TILES: dict[str, tuple[str, str]] = {
    "flood": (
        "https://disaportaldata.gsi.go.jp/raster/01_flood_l2_shinsuishin_data/{z}/{x}/{y}.png",
        "洪水浸水想定",
    ),
    "sediment": (
        "https://disaportaldata.gsi.go.jp/raster/05_dosekiryukeikaikuiki/{z}/{x}/{y}.png",
        "土砂災害警戒",
    ),
    "storm_surge": (
        "https://disaportaldata.gsi.go.jp/raster/03_hightide_l2_shinsuishin_data/{z}/{x}/{y}.png",
        "高潮浸水想定",
    ),
    "tsunami": (
        "https://disaportaldata.gsi.go.jp/raster/04_tsunami_newlegend_data/{z}/{x}/{y}.png",
        "津波浸水想定",
    ),
    "liquefaction": (
        # 08_liquid は GSI オープンデータ非公開 (404) のため治水地形分類図で代替
        "https://cyberjapandata.gsi.go.jp/xyz/lcmfc2/{z}/{x}/{y}.png",
        "液状化（地形分類）",
    ),
    "inland_water": (
        "https://disaportaldata.gsi.go.jp/raster/02_naisui_data/{z}/{x}/{y}.png",
        "内水浸水想定",
    ),
}

# HTTP セッション（Keep-Alive）
_session = requests.Session()
_session.headers.update({"User-Agent": "real-estate-hazard-enricher/1.0"})

# タイルキャッシュ（同一座標近傍の物件で同じタイルを再取得しない）
_tile_cache: dict[str, Optional[bytes]] = {}
_tile_cache_lock = Lock()

# ────────────────────────────────────────────────────────
# 東京都地域危険度 GeoJSON 設定
# ────────────────────────────────────────────────────────

RISK_GEOJSON_DIR = Path(__file__).resolve().parent / "results" / "risk_geojson"
# フォールバック: data/tokyo_risk/ も探す
RISK_GEOJSON_DIR_ALT = Path(__file__).resolve().parent / "data" / "tokyo_risk"

RISK_TYPES = {
    "building_collapse": "building_collapse_risk.geojson",
    "fire": "fire_risk.geojson",
    "combined": "combined_risk.geojson",
}

# ロード済み GeoJSON フィーチャー
_risk_features: dict[str, list[dict]] = {}

# ────────────────────────────────────────────────────────
# 座標 → タイル変換ユーティリティ
# ────────────────────────────────────────────────────────


def _latlng_to_tile(lat: float, lng: float, zoom: int) -> tuple[int, int, int, int]:
    """
    緯度経度をタイル座標 (tile_x, tile_y) とタイル内ピクセル位置 (px_x, px_y) に変換。
    タイルサイズは 256x256。
    """
    n = 2**zoom
    x_float = (lng + 180.0) / 360.0 * n
    lat_rad = math.radians(lat)
    y_float = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * n

    tile_x = int(x_float)
    tile_y = int(y_float)
    px_x = int((x_float - tile_x) * 256)
    px_y = int((y_float - tile_y) * 256)

    # クリッピング
    px_x = max(0, min(255, px_x))
    px_y = max(0, min(255, px_y))

    return tile_x, tile_y, px_x, px_y


TILE_FETCH_RETRIES = 3
TILE_FETCH_BACKOFF_SEC = 2


def _fetch_tile(url: str) -> Optional[bytes]:
    """タイル画像を取得（キャッシュ付き）。404/エラーなら None。2–3回リトライしてから None をキャッシュ。"""
    with _tile_cache_lock:
        if url in _tile_cache:
            return _tile_cache[url]
    for attempt in range(TILE_FETCH_RETRIES):
        try:
            resp = _session.get(url, timeout=10)
            if resp.status_code == 200 and len(resp.content) > 100:
                content = resp.content
                with _tile_cache_lock:
                    _tile_cache[url] = content
                return content
        except requests.RequestException:
            pass
        if attempt < TILE_FETCH_RETRIES - 1:
            time.sleep(TILE_FETCH_BACKOFF_SEC * (attempt + 1))
    with _tile_cache_lock:
        if url not in _tile_cache:
            _tile_cache[url] = None
    return None


def _check_tile_pixel(tile_data: bytes, px_x: int, px_y: int) -> bool:
    """
    タイル画像の指定ピクセルが非透明かどうかを判定。
    PIL（Pillow）がインストールされていれば正確にチェック、なければタイルが存在すること自体をハザードありとみなす。
    """
    try:
        from PIL import Image
        img = Image.open(io.BytesIO(tile_data)).convert("RGBA")
        if px_x >= img.width or px_y >= img.height:
            return False
        _, _, _, alpha = img.getpixel((px_x, px_y))
        return alpha > 30  # ほぼ透明でなければハザードあり
    except ImportError:
        # PIL がない場合はタイルの存在をもってハザードありとする
        return True
    except Exception:
        return False


def check_gsi_hazard(lat: float, lng: float, hazard_key: str) -> bool:
    """指定座標が GSI ハザードマップタイルでハザード該当かどうかを返す。"""
    if hazard_key not in GSI_HAZARD_TILES:
        return False

    url_template, _ = GSI_HAZARD_TILES[hazard_key]
    tile_x, tile_y, px_x, px_y = _latlng_to_tile(lat, lng, TILE_ZOOM)
    url = url_template.replace("{z}", str(TILE_ZOOM)).replace("{x}", str(tile_x)).replace("{y}", str(tile_y))

    tile_data = _fetch_tile(url)
    if tile_data is None:
        return False

    return _check_tile_pixel(tile_data, px_x, px_y)


# ────────────────────────────────────────────────────────
# 東京都地域危険度 GeoJSON 判定
# ────────────────────────────────────────────────────────


def _load_risk_geojson() -> None:
    """東京都地域危険度 GeoJSON をロードする。"""
    global _risk_features
    if _risk_features:
        return  # ロード済み

    for risk_key, filename in RISK_TYPES.items():
        path = RISK_GEOJSON_DIR / filename
        if not path.exists():
            path = RISK_GEOJSON_DIR_ALT / filename
        if not path.exists():
            print(f"  地域危険度 GeoJSON が見つかりません: {filename}", file=sys.stderr)
            continue

        try:
            with open(path, encoding="utf-8") as f:
                geojson = json.load(f)
            _risk_features[risk_key] = geojson.get("features", [])
            print(f"  地域危険度 {risk_key}: {len(_risk_features[risk_key])} features ロード", file=sys.stderr)
        except (json.JSONDecodeError, OSError) as e:
            print(f"  地域危険度 GeoJSON 読み込みエラー ({filename}): {e}", file=sys.stderr)


def _point_in_polygon(px: float, py: float, polygon: list[list[float]]) -> bool:
    """
    レイキャスティングで点 (px, py) がポリゴン内にあるか判定。
    polygon は [[lng, lat], [lng, lat], ...] のリスト。
    """
    n = len(polygon)
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = polygon[i][0], polygon[i][1]
        xj, yj = polygon[j][0], polygon[j][1]
        if ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def _point_in_geometry(lat: float, lng: float, geometry: dict) -> bool:
    """GeoJSON Geometry 内に点が含まれるか判定。"""
    geom_type = geometry.get("type", "")
    coords = geometry.get("coordinates", [])

    if geom_type == "Polygon":
        # 外周リング（最初のリング）だけでチェック
        if coords and len(coords) > 0:
            return _point_in_polygon(lng, lat, coords[0])
    elif geom_type == "MultiPolygon":
        for polygon in coords:
            if polygon and len(polygon) > 0:
                if _point_in_polygon(lng, lat, polygon[0]):
                    return True
    return False


def check_tokyo_risk(lat: float, lng: float, risk_key: str) -> int:
    """
    指定座標の東京都地域危険度ランク (1-5) を返す。該当なしなら 0。
    """
    _load_risk_geojson()

    features = _risk_features.get(risk_key, [])
    for feature in features:
        geometry = feature.get("geometry")
        properties = feature.get("properties", {})
        if geometry and _point_in_geometry(lat, lng, geometry):
            return int(properties.get("rank", 0))
    return 0


# ────────────────────────────────────────────────────────
# メイン: 物件リストにハザード情報を付与
# ────────────────────────────────────────────────────────


def enrich_hazard(listings: list[dict]) -> list[dict]:
    """
    各物件に hazard_info フィールドを追加する。
    座標（latitude, longitude）がない物件はスキップ。
    """
    # ジオコーディング済みの座標を利用
    # 座標がない物件はスクレイピング時に geocode.py で付与されている前提
    # geocode_cache.json からも取得可能
    geocode_cache = _load_geocode_cache()

    total = len(listings)
    enriched_count = 0
    hazard_count = 0

    print(f"ハザード enrichment 開始: {total} 件", file=sys.stderr)

    for i, listing in enumerate(listings):
        lat = listing.get("latitude")
        lng = listing.get("longitude")

        # 座標がなければジオコードキャッシュから取得（ss_address 優先）
        if lat is None or lng is None:
            for addr_key in ("ss_address", "address"):
                addr_val = (listing.get(addr_key) or "").strip()
                if addr_val:
                    cached = geocode_cache.get(addr_val)
                    if cached:
                        lat, lng = cached
                        break

        if lat is None or lng is None:
            continue

        hazard: dict[str, Any] = {}

        # GSI ハザードタイルチェック（タイル種別ごとに並列取得）
        def _check_one(key: str) -> tuple[str, bool]:
            time.sleep(0.05)  # タイルサーバーへの負荷軽減（GSI の利用規約に配慮）
            try:
                return (key, check_gsi_hazard(lat, lng, key))
            except Exception:
                return (key, False)

        with ThreadPoolExecutor(max_workers=5) as executor:
            results = list(executor.map(_check_one, GSI_HAZARD_TILES))
        for key, value in results:
            hazard[key] = value

        # 東京都地域危険度チェック
        for key in RISK_TYPES:
            try:
                hazard[key] = check_tokyo_risk(lat, lng, key)
            except Exception:
                hazard[key] = 0

        listing["hazard_info"] = json.dumps(hazard, ensure_ascii=False)
        enriched_count += 1

        has_any = (
            hazard.get("flood", False)
            or hazard.get("sediment", False)
            or hazard.get("storm_surge", False)
            or hazard.get("tsunami", False)
            or hazard.get("liquefaction", False)
            or hazard.get("inland_water", False)
            or hazard.get("building_collapse", 0) >= 3
            or hazard.get("fire", 0) >= 3
            or hazard.get("combined", 0) >= 3
        )
        if has_any:
            hazard_count += 1

        if (i + 1) % 10 == 0 or i + 1 == total:
            print(f"  進捗: {i + 1}/{total} (ハザード該当: {hazard_count}件)", file=sys.stderr)

    print(f"ハザード enrichment 完了: {enriched_count}/{total} 件処理, {hazard_count} 件ハザード該当", file=sys.stderr)
    return listings


def _load_geocode_cache() -> dict[str, tuple[float, float]]:
    """ジオコードキャッシュを読み込む。"""
    cache_path = Path(__file__).resolve().parent / "data" / "geocode_cache.json"
    if not cache_path.exists():
        return {}
    try:
        with open(cache_path, encoding="utf-8") as f:
            data = json.load(f)
        return {k: tuple(v) for k, v in data.items()}
    except (json.JSONDecodeError, TypeError, OSError):
        return {}


def main() -> None:
    ap = argparse.ArgumentParser(description="物件リストにハザード情報を付与する")
    ap.add_argument("--input", "-i", required=True, help="入力 JSON ファイル")
    ap.add_argument("--output", "-o", required=True, help="出力 JSON ファイル")
    args = ap.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"エラー: {input_path} が見つかりません", file=sys.stderr)
        sys.exit(1)

    with open(input_path, encoding="utf-8") as f:
        listings = json.load(f)

    listings = enrich_hazard(listings)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    # 原子的書き込み: tmp に書いてからリネームし、途中クラッシュでも既存ファイルを壊さない
    tmp_path = output_path.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp_path.replace(output_path)

    print(f"保存: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
