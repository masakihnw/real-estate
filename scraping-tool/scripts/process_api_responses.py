#!/usr/bin/env python3
"""
reinfolib API レスポンスの JSON ファイル群を読み込み、
区別・四半期別の m² 単価中央値を集計して ward_price_history.json を出力する。

全ファイルの中から MunicipalityCode (13101-13123) と Period を自動判別するため、
ファイル名の命名規則に依存しない。

usage:
  python3 scripts/process_api_responses.py <json_file_or_dir> [<json_file_or_dir> ...]
  # 結果は data/ward_price_history.json に保存
"""

import json
import os
import re
import statistics
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.dirname(SCRIPT_DIR)
OUTPUT_FILE = os.path.join(BASE_DIR, "data", "ward_price_history.json")

WARD_CODE_TO_NAME = {
    "13101": "千代田区", "13102": "中央区", "13103": "港区",
    "13104": "新宿区", "13105": "文京区", "13106": "台東区",
    "13107": "墨田区", "13108": "江東区", "13109": "品川区",
    "13110": "目黒区", "13111": "大田区", "13112": "世田谷区",
    "13113": "渋谷区", "13114": "中野区", "13115": "杉並区",
    "13116": "豊島区", "13117": "北区", "13118": "荒川区",
    "13119": "板橋区", "13120": "練馬区", "13121": "足立区",
    "13122": "葛飾区", "13123": "江戸川区",
}

PERIOD_RE = re.compile(r"(\d{4})年第(\d)四半期")


def parse_period(period_str: str) -> Optional[str]:
    """'2021年第2四半期' → '2021Q2'"""
    m = PERIOD_RE.match(period_str)
    if m:
        return f"{m.group(1)}Q{m.group(2)}"
    return None


def process_file(fpath: str) -> Dict[str, Dict[str, List[float]]]:
    """
    1つのJSONファイルから ward_name → {quarter: [m2_prices]} を抽出。
    """
    result: Dict[str, Dict[str, List[float]]] = {}
    try:
        with open(fpath, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return result

    items = data.get("data", [])
    if not items:
        return result

    for item in items:
        if "中古マンション" not in item.get("Type", ""):
            continue

        mcode = item.get("MunicipalityCode", "")
        ward_name = WARD_CODE_TO_NAME.get(mcode)
        if not ward_name:
            continue

        period = item.get("Period", "")
        qlabel = parse_period(period)
        if not qlabel:
            continue

        try:
            price = float(str(item.get("TradePrice", "0")).replace(",", ""))
            area = float(str(item.get("Area", "0")).replace(",", ""))
            if price > 0 and area > 0:
                m2_price = price / area
                if ward_name not in result:
                    result[ward_name] = {}
                if qlabel not in result[ward_name]:
                    result[ward_name][qlabel] = []
                result[ward_name][qlabel].append(m2_price)
        except (ValueError, TypeError):
            continue

    return result


def merge_results(
    accumulated: Dict[str, Dict[str, List[float]]],
    new_data: Dict[str, Dict[str, List[float]]],
):
    """new_data を accumulated にマージ。"""
    for ward_name, quarters in new_data.items():
        if ward_name not in accumulated:
            accumulated[ward_name] = {}
        for qlabel, prices in quarters.items():
            if qlabel not in accumulated[ward_name]:
                accumulated[ward_name][qlabel] = []
            accumulated[ward_name][qlabel].extend(prices)


def build_output(
    accumulated: Dict[str, Dict[str, List[float]]]
) -> dict:
    """集計結果を ward_price_history.json 形式に変換。"""
    by_ward = {}
    for ward_name in sorted(accumulated.keys()):
        quarters = {}
        for qlabel in sorted(accumulated[ward_name].keys()):
            prices = accumulated[ward_name][qlabel]
            if prices:
                quarters[qlabel] = {
                    "median_m2_price": round(statistics.median(prices)),
                    "mean_m2_price": round(statistics.mean(prices)),
                    "count": len(prices),
                }
        by_ward[ward_name] = {"quarters": quarters}

    return {
        "by_ward": by_ward,
        "data_source": "不動産情報ライブラリ（国土交通省）",
    }


def collect_files(paths: List[str]) -> List[str]:
    """指定パスからJSONファイルのリストを収集。"""
    files = []
    for p in paths:
        if os.path.isfile(p) and p.endswith(".json"):
            files.append(p)
        elif os.path.isfile(p) and p.endswith(".txt"):
            # agent-tools の出力ファイル（.txt だがJSON形式の場合）
            files.append(p)
        elif os.path.isdir(p):
            for fname in os.listdir(p):
                fpath = os.path.join(p, fname)
                if os.path.isfile(fpath) and (fname.endswith(".json") or fname.endswith(".txt")):
                    files.append(fpath)
    return sorted(files)


def main():
    if len(sys.argv) < 2:
        print("usage: python3 process_api_responses.py <file_or_dir> [...]", file=sys.stderr)
        sys.exit(1)

    files = collect_files(sys.argv[1:])
    print(f"処理対象: {len(files)} ファイル", file=sys.stderr)

    accumulated: Dict[str, Dict[str, List[float]]] = {}
    total_records = 0

    for fpath in files:
        result = process_file(fpath)
        if result:
            for ward, quarters in result.items():
                for ql, prices in quarters.items():
                    total_records += len(prices)
            merge_results(accumulated, result)
            ward_count = sum(len(qs) for qs in result.values())
            print(f"  {os.path.basename(fpath)}: {ward_count} ward-quarter(s)", file=sys.stderr)

    output = build_output(accumulated)

    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)

    ward_count = len(output["by_ward"])
    quarter_set = set()
    for wd in output["by_ward"].values():
        quarter_set.update(wd["quarters"].keys())

    print(f"\n=== 結果 ===", file=sys.stderr)
    print(f"区数: {ward_count}", file=sys.stderr)
    print(f"四半期数: {len(quarter_set)}", file=sys.stderr)
    print(f"総レコード: {total_records}", file=sys.stderr)
    print(f"期間: {min(quarter_set)} 〜 {max(quarter_set)}", file=sys.stderr)
    print(f"出力: {OUTPUT_FILE}", file=sys.stderr)


if __name__ == "__main__":
    main()
