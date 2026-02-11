#!/usr/bin/env python3
"""
東京都都市整備局の地域危険度測定調査 Shapefile を GeoJSON に変換する。

出力:
  results/risk_geojson/building_collapse_risk.geojson  -- 建物倒壊危険度 (rank 1-5)
  results/risk_geojson/fire_risk.geojson               -- 火災危険度 (rank 1-5)
  results/risk_geojson/combined_risk.geojson            -- 総合危険度 (rank 1-5)

使い方:
  pip install geopandas shapely fiona
  python3 scripts/convert_risk_geojson.py

GeoJSON は GitHub raw URL 経由で iOS アプリから取得し、MKPolygon としてオーバーレイ表示する。
"""

from __future__ import annotations

import io
import json
import os
import sys
import zipfile
from pathlib import Path

import requests

# SHP ダウンロード URL（東京都都市整備局 地域危険度測定調査 第9回）
SHP_URL = "https://www.toshiseibi.metro.tokyo.lg.jp/bosai/chousa_6/download/all2.zip"

OUTPUT_DIR = Path(__file__).parent.parent / "results" / "risk_geojson"

# 各危険度の列名（Shapefile の属性名）
# 第9回調査 Shapefile の属性名は調査ごとに異なる可能性があるため、
# 代替候補も含めて検索する。
RANK_COLUMNS = {
    "building_collapse_risk": {
        "candidates": ["建物_ラ", "RANK_BUILD", "建物倒壊", "rank_build", "RANK1", "建物倒壊危険度ランク"],
        "label": "建物倒壊危険度",
    },
    "fire_risk": {
        "candidates": ["火災_ラ", "RANK_FIRE", "火災危険", "rank_fire", "RANK2", "火災危険度ランク"],
        "label": "火災危険度",
    },
    "combined_risk": {
        "candidates": ["総合_ラ", "RANK_TOTAL", "総合危険", "rank_total", "RANK3", "総合危険度ランク"],
        "label": "総合危険度",
    },
}


def download_shp(url: str) -> Path:
    """SHP ZIP をダウンロードし、一時ディレクトリに展開して SHP ファイルパスを返す。"""
    import tempfile

    print(f"ダウンロード中: {url}", file=sys.stderr)
    resp = requests.get(url, timeout=120)
    resp.raise_for_status()

    tmpdir = Path(tempfile.mkdtemp(prefix="tokyo_risk_"))
    with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
        zf.extractall(tmpdir)

    # SHP ファイルを探す
    shp_files = list(tmpdir.rglob("*.shp"))
    if not shp_files:
        raise FileNotFoundError(f"SHP ファイルが見つかりません: {tmpdir}")

    print(f"SHP: {shp_files[0]}", file=sys.stderr)
    return shp_files[0]


def find_rank_column(columns: list[str], candidates: list[str]) -> str | None:
    """属性名候補からマッチする列名を返す。完全一致を優先し、次に部分一致を試す。"""
    # 完全一致
    for cand in candidates:
        if cand in columns:
            return cand
    # 部分一致（大文字小文字無視）
    for cand in candidates:
        for col in columns:
            if cand.lower() in col.lower():
                return col
    return None


def convert_to_geojson(shp_path: Path) -> None:
    """SHP を読み込み、3種類の GeoJSON に変換して保存する。"""
    try:
        import geopandas as gpd
    except ImportError:
        print("geopandas が必要です: pip install geopandas shapely fiona", file=sys.stderr)
        sys.exit(1)

    gdf = gpd.read_file(shp_path)

    # Shapefile の属性名を確認
    print(f"属性列: {list(gdf.columns)}", file=sys.stderr)
    print(f"レコード数: {len(gdf)}", file=sys.stderr)

    # CRS を WGS84 (EPSG:4326) に変換
    if gdf.crs and gdf.crs.to_epsg() != 4326:
        print(f"CRS 変換: {gdf.crs} -> EPSG:4326", file=sys.stderr)
        gdf = gdf.to_crs(epsg=4326)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # 全属性から数値列を探してランク候補を推測
    numeric_cols = [c for c in gdf.columns if gdf[c].dtype in ("int64", "float64", "int32", "float32")]
    print(f"数値列: {numeric_cols}", file=sys.stderr)

    # 町丁目名の列を探す
    name_col = None
    for cand in ["町丁目名", "町丁目", "CHOME", "S_NAME", "NAME", "name", "MOJI"]:
        for col in gdf.columns:
            if cand.lower() in col.lower():
                name_col = col
                break
        if name_col:
            break

    for output_name, config in RANK_COLUMNS.items():
        rank_col = find_rank_column(list(gdf.columns), config["candidates"])

        if rank_col is None:
            # フォールバック: 数値列から順番に割り当て
            print(f"警告: {config['label']} の列が見つかりません。数値列から推測します。", file=sys.stderr)
            # RANK1, RANK2, RANK3 のようなパターンを探す
            idx = list(RANK_COLUMNS.keys()).index(output_name)
            rank_like = [c for c in numeric_cols if "rank" in c.lower() or "危険" in c.lower()]
            if idx < len(rank_like):
                rank_col = rank_like[idx]
                print(f"  -> {rank_col} を使用", file=sys.stderr)
            elif idx < len(numeric_cols):
                rank_col = numeric_cols[idx]
                print(f"  -> {rank_col} を使用（推測）", file=sys.stderr)
            else:
                print(f"  -> スキップ（適切な列が見つかりません）", file=sys.stderr)
                continue

        print(f"{config['label']}: 列={rank_col}, 値範囲={gdf[rank_col].min()}-{gdf[rank_col].max()}", file=sys.stderr)

        # GeoJSON 用のデータフレームを作成
        features = []
        for _, row in gdf.iterrows():
            geom = row.geometry
            if geom is None or geom.is_empty:
                continue

            rank = int(row[rank_col]) if not (row[rank_col] is None or str(row[rank_col]) == "nan") else 0
            # ランクが 1-5 の範囲外の場合はクリップ
            rank = max(0, min(5, rank))

            props = {
                "rank": rank,
                "label": config["label"],
            }
            if name_col and row.get(name_col):
                props["name"] = str(row[name_col])

            # GeoJSON Feature を手動で作成（軽量化のため座標精度を制限）
            from shapely.geometry import mapping
            geojson_geom = mapping(geom)
            geojson_geom = _round_coordinates(dict(geojson_geom), precision=5)

            features.append({
                "type": "Feature",
                "properties": props,
                "geometry": geojson_geom,
            })

        geojson = {
            "type": "FeatureCollection",
            "features": features,
        }

        output_path = OUTPUT_DIR / f"{output_name}.geojson"
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(geojson, f, ensure_ascii=False)

        file_size_mb = output_path.stat().st_size / (1024 * 1024)
        print(f"保存: {output_path} ({len(features)} features, {file_size_mb:.1f} MB)", file=sys.stderr)


def _round_coordinates(geojson_geom: dict, precision: int = 5) -> dict:
    """GeoJSON ジオメトリの座標精度を制限してファイルサイズを削減する。"""

    def _round(coords):
        if isinstance(coords, (list, tuple)):
            if len(coords) > 0 and isinstance(coords[0], (int, float)):
                return [round(c, precision) for c in coords]
            return [_round(c) for c in coords]
        return coords

    if "coordinates" in geojson_geom:
        geojson_geom["coordinates"] = _round(geojson_geom["coordinates"])
    return geojson_geom


def main() -> None:
    shp_path = download_shp(SHP_URL)
    convert_to_geojson(shp_path)
    print("変換完了", file=sys.stderr)


if __name__ == "__main__":
    main()
