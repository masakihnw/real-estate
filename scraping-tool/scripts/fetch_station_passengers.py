#!/usr/bin/env python3
"""
駅別乗降客数データを取得し、data/station_passengers.json に保存する。
国土数値情報（駅別乗降客数データ S12）を利用。config.STATION_PASSENGERS_MIN > 0 にすると、
このデータを元に乗降客数が少ない駅の物件をフィルタできる。

使い方:
  1) 手動で国土数値情報からダウンロード:
     https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-S12-v3_1.html
     「S12-22_GML.zip」（令和3年・全国）をダウンロードし、scraping-tool/data/ に置く。
  2) python scripts/fetch_station_passengers.py
     → data/S12-22_GML.zip を読み、data/station_passengers.json を生成する。

  または ZIP のパスを引数で指定:
     python scripts/fetch_station_passengers.py /path/to/S12-22_GML.zip
"""

import json
import re
import sys
import zipfile
from pathlib import Path

# スクリプト配置が scraping-tool/ である前提
ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
OUT_PATH = DATA_DIR / "station_passengers.json"
DEFAULT_ZIP = DATA_DIR / "S12-22_GML.zip"


def _parse_gml_for_stations(gml_text: str) -> dict[str, int]:
    """GML/XML テキストから駅名と乗降客数（2021優先）を抽出。同一駅名は最大値を採用。"""
    result: dict[str, int] = {}
    # S12-22: ksj:TheNumberofTheStationPassengersGettingonandoff でブロック分割
    blocks = re.split(
        r"<ksj:TheNumberofTheStationPassengersGettingonandoff[^>]*>",
        gml_text,
        flags=re.I,
    )
    # 駅名: ksj:stationName（S12-22）または S12_001（旧GML）
    pattern_name = re.compile(
        r"<ksj:stationName[^>]*>([^<]+)</ksj:stationName>"
        r"|<(?:ksj:)?S12_001[^>]*>([^<]+)</(?:ksj:)?S12_001>",
        re.I,
    )
    # 乗降客数: passengers2021（S12-22）または S12_049（旧GML）
    pattern_2021 = re.compile(
        r"<ksj:passengers2021[^>]*>(\d+)</ksj:passengers2021>"
        r"|<(?:ksj:)?S12_049[^>]*>(\d+)</(?:ksj:)?S12_049>",
        re.I,
    )
    for block in blocks:
        name_m = pattern_name.search(block)
        if not name_m:
            continue
        name = (name_m.group(1) or name_m.group(2) or "").strip()
        if not name:
            continue
        val_m = pattern_2021.search(block)
        try:
            val = int(val_m.group(1) or val_m.group(2) or 0) if val_m else 0
        except (ValueError, AttributeError):
            val = 0
        if name not in result or result[name] < val:
            result[name] = val
    return result


def main() -> None:
    zip_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ZIP
    if not zip_path.exists():
        print(
            f"ZIP がありません: {zip_path}\n"
            "国土数値情報から S12-22_GML.zip をダウンロードし、data/ に置いてください。\n"
            "https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-S12-v3_1.html",
            file=sys.stderr,
        )
        sys.exit(1)

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    all_stations: dict[str, int] = {}

    with zipfile.ZipFile(zip_path, "r") as zf:
        for name in zf.namelist():
            if not (name.endswith(".xml") or name.endswith(".gml")):
                continue
            # Shift-JIS フォルダ内のファイルは UTF-8 として読むと文字化けするためスキップ
            if "Shift-JIS" in name or "Shift_JIS" in name:
                continue
            with zf.open(name) as f:
                try:
                    text = f.read().decode("utf-8", errors="replace")
                except Exception:
                    continue
                part = _parse_gml_for_stations(text)
                for k, v in part.items():
                    if k not in all_stations or all_stations[k] < v:
                        all_stations[k] = v

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(all_stations, f, ensure_ascii=False, indent=2)
    print(f"保存しました: {OUT_PATH} ({len(all_stations)}駅)", file=sys.stderr)


if __name__ == "__main__":
    main()
