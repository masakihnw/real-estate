#!/usr/bin/env python3
"""
東京都内の全駅について、MCP経由 or 直接APIで reinfolib から
成約価格/取引価格データを並列取得し、駅別・年別＋四半期別の m² 単価中央値を算出する。

usage:
  # MCP経由（APIキー不要）
  python3 scripts/fetch_station_prices.py [--workers 8] [--years 5]

  # 直接API（APIキー必要）
  REINFOLIB_API_KEY=xxx python3 scripts/fetch_station_prices.py --direct-api

出力:
  data/station_price_history.json
    by_station.<駅名>.years    — 年別統計 (median/mean/count)
    by_station.<駅名>.quarters — 四半期別統計 (median/mean/count)
"""

import argparse
import json
import os
import re
import statistics
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

try:
    import requests
except ImportError:
    print("requests が必要です: pip install requests", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# パス設定
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.dirname(SCRIPT_DIR)
DATA_DIR = os.path.join(BASE_DIR, "data")

STATION_CODES_FILE = os.path.join(DATA_DIR, "tokyo_station_codes.json")
AREA_COEFFICIENTS_FILE = os.path.join(DATA_DIR, "area_coefficients.csv")
OUTPUT_FILE = os.path.join(DATA_DIR, "station_price_history.json")

# ---------------------------------------------------------------------------
# API / MCP 設定
# ---------------------------------------------------------------------------
MCP_URL = "https://mcp.n-3.ai/mcp?tools=reinfolib-real-estate-price"
MCP_TOOL_NAME = "reinfolib-real-estate-price"

DIRECT_API_BASE = "https://www.reinfolib.mlit.go.jp/ex-api/external"
DIRECT_API_ENDPOINT = f"{DIRECT_API_BASE}/XIT001"

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


# ---------------------------------------------------------------------------
# MCP クライアント
# ---------------------------------------------------------------------------
class MCPClient:
    """Streamable HTTP MCP クライアント。"""

    def __init__(self, url: str):
        self.url = url
        self.session = requests.Session()
        self.session.headers.update({
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        })
        self._request_id = 0
        self._initialized = False

    def _next_id(self) -> int:
        self._request_id += 1
        return self._request_id

    def _send_jsonrpc(self, method: str, params: dict) -> dict:
        """JSON-RPC リクエストを送信し、SSE レスポンスをパース。"""
        req = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": method,
            "params": params,
        }
        resp = self.session.post(self.url, json=req, timeout=120)
        resp.raise_for_status()

        # SSE パース（text/event-stream は charset 未指定 → UTF-8 で強制デコード）
        text = resp.content.decode("utf-8")
        for line in text.split("\n"):
            if line.startswith("data:"):
                data = json.loads(line[5:].strip())
                if "result" in data:
                    return data["result"]
                if "error" in data:
                    raise RuntimeError(f"MCP error: {data['error']}")
        raise RuntimeError("No result in SSE response")

    def initialize(self):
        if self._initialized:
            return
        self._send_jsonrpc("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "station-fetcher", "version": "1.0"},
        })
        self._initialized = True

    def call_tool(self, name: str, arguments: dict) -> str:
        """MCP ツールを呼び出し、テキスト結果を返す。"""
        self.initialize()
        result = self._send_jsonrpc("tools/call", {
            "name": name,
            "arguments": arguments,
        })
        texts = []
        for content in result.get("content", []):
            if content.get("type") == "text":
                texts.append(content["text"])
        return "\n".join(texts)


# ---------------------------------------------------------------------------
# データフェッチ
# ---------------------------------------------------------------------------
def fetch_via_mcp(station_code: str, year: int, limit: int = 100) -> List[dict]:
    """MCP経由で1駅1年分を取得。"""
    client = MCPClient(MCP_URL)
    try:
        text = client.call_tool(MCP_TOOL_NAME, {
            "year": str(year),
            "station": station_code,
            "priceClassification": "01",
            "limit": limit,
            "language": "ja",
        })
        data = json.loads(text)
        return data.get("data", [])
    except Exception as e:
        return []


def fetch_via_direct_api(
    station_code: str, year: int, api_key: str
) -> List[dict]:
    """直接API経由で1駅1年分を取得（件数制限なし）。"""
    params = {
        "year": year,
        "station": station_code,
        "priceClassification": "01",
    }
    headers = {"Ocp-Apim-Subscription-Key": api_key}
    try:
        resp = requests.get(
            DIRECT_API_ENDPOINT, headers=headers, params=params, timeout=60
        )
        if resp.status_code == 200:
            return resp.json().get("data", [])
    except Exception:
        pass
    return []


# ---------------------------------------------------------------------------
# 四半期パース
# ---------------------------------------------------------------------------
PERIOD_RE = re.compile(r"(\d{4})年第(\d)四半期")


def parse_quarter_label(period: str) -> Optional[str]:
    """'2025年第3四半期' → '2025Q3'"""
    m = PERIOD_RE.search(period)
    if m:
        return f"{m.group(1)}Q{m.group(2)}"
    return None


# ---------------------------------------------------------------------------
# データ処理
# ---------------------------------------------------------------------------
def _extract_m2_prices(items: List[dict]) -> List[float]:
    """中古マンション取引からm²単価リストを抽出。"""
    m2_prices = []
    for item in items:
        type_str = item.get("Type", "")
        if "中古マンション" not in type_str:
            continue
        try:
            price = float(str(item.get("TradePrice", "0")).replace(",", ""))
            area = float(str(item.get("Area", "0")).replace(",", ""))
            if price > 0 and area > 0:
                m2_prices.append(price / area)
        except (ValueError, TypeError):
            continue
    return m2_prices


def _stats_from_prices(m2_prices: List[float]) -> Optional[Dict[str, Any]]:
    """m²単価リストから統計値を算出。"""
    if not m2_prices:
        return None
    return {
        "median_m2_price": round(statistics.median(m2_prices)),
        "mean_m2_price": round(statistics.mean(m2_prices)),
        "count": len(m2_prices),
    }


def compute_m2_stats(items: List[dict]) -> Optional[Dict[str, Any]]:
    """中古マンションの m² 単価統計を算出。"""
    return _stats_from_prices(_extract_m2_prices(items))


def compute_quarterly_m2_stats(
    items: List[dict],
) -> Dict[str, Dict[str, Any]]:
    """
    アイテムを四半期別に分割し、各四半期の統計を算出。
    Returns: {"2025Q1": {"median_m2_price": ..., "mean_m2_price": ..., "count": ...}, ...}
    """
    by_quarter: Dict[str, List[dict]] = {}
    for item in items:
        period = item.get("Period", "")
        ql = parse_quarter_label(period)
        if ql:
            by_quarter.setdefault(ql, []).append(item)

    result: Dict[str, Dict[str, Any]] = {}
    for ql, q_items in by_quarter.items():
        stats = compute_m2_stats(q_items)
        if stats:
            result[ql] = stats
    return result


def detect_ward(items: List[dict]) -> Optional[str]:
    """最頻出の区名を返す。"""
    codes = [item.get("MunicipalityCode", "") for item in items]
    codes = [c for c in codes if c in WARD_CODE_TO_NAME]
    if not codes:
        return None
    return WARD_CODE_TO_NAME.get(Counter(codes).most_common(1)[0][0])


# ---------------------------------------------------------------------------
# ワーカー
# ---------------------------------------------------------------------------
def process_one(
    station: dict, year: int, use_direct: bool, api_key: str
) -> Optional[Tuple[str, str, int, dict, Dict[str, dict], Optional[str]]]:
    """
    1駅1年を処理。
    Returns: (name, code, year, yearly_stats, quarterly_stats, ward) or None
    """
    code = station["group_code"]
    name = station["station_name"]

    if use_direct:
        items = fetch_via_direct_api(code, year, api_key)
    else:
        items = fetch_via_mcp(code, year)

    stats = compute_m2_stats(items)
    quarterly = compute_quarterly_m2_stats(items)
    ward = detect_ward(items)

    if stats:
        return (name, code, year, stats, quarterly, ward)
    return None


# ---------------------------------------------------------------------------
# ファイル I/O
# ---------------------------------------------------------------------------
def load_station_codes() -> List[dict]:
    with open(STATION_CODES_FILE, "r", encoding="utf-8") as f:
        return json.load(f).get("stations", [])


def load_area_tiers() -> Dict[str, str]:
    """area_coefficients.csv → {駅名: tier}"""
    import csv
    tiers: Dict[str, str] = {}
    if os.path.exists(AREA_COEFFICIENTS_FILE):
        with open(AREA_COEFFICIENTS_FILE, "r", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                tiers[row.get("station_name", "")] = row.get("area_rank", "Other")
    return tiers


def save_output(results: dict, years: list):
    os.makedirs(DATA_DIR, exist_ok=True)
    output = {
        "by_station": results,
        "years": [str(y) for y in years],
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "data_source": "不動産情報ライブラリ（国土交通省）",
    }
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="駅別 m² 単価データ並列取得")
    ap.add_argument("--workers", type=int, default=8,
                    help="並列ワーカー数 (default: 8)")
    ap.add_argument("--years", type=int, default=5,
                    help="取得年数 (default: 5)")
    ap.add_argument("--limit-stations", type=int, default=0,
                    help="駅数上限 (0=全駅)")
    ap.add_argument("--priority-only", action="store_true",
                    help="area_coefficients.csv の駅のみ")
    ap.add_argument("--resume", action="store_true",
                    help="既存出力があれば差分取得")
    ap.add_argument("--direct-api", action="store_true",
                    help="直接API使用 (要 REINFOLIB_API_KEY)")
    args = ap.parse_args()

    use_direct = args.direct_api
    api_key = ""
    if use_direct:
        api_key = os.environ.get("REINFOLIB_API_KEY", "")
        if not api_key:
            print("エラー: REINFOLIB_API_KEY を設定してください", file=sys.stderr)
            sys.exit(1)

    current_year = datetime.now().year
    years = list(range(current_year - args.years + 1, current_year + 1))

    stations = load_station_codes()
    tiers = load_area_tiers()

    if args.priority_only:
        priority_names = set(tiers.keys())
        stations = [s for s in stations if s["station_name"] in priority_names]

    if args.limit_stations > 0:
        stations = stations[:args.limit_stations]

    print(f"=== 駅別 m² 単価データ取得 ===", file=sys.stderr)
    print(f"モード: {'直接API' if use_direct else 'MCP経由'}", file=sys.stderr)
    print(f"対象駅: {len(stations)}", file=sys.stderr)
    print(f"対象年: {years[0]}〜{years[-1]} ({len(years)}年)", file=sys.stderr)
    print(f"並列数: {args.workers}", file=sys.stderr)

    # 既存データ
    existing: Dict[str, Any] = {}
    if args.resume and os.path.exists(OUTPUT_FILE):
        with open(OUTPUT_FILE, "r", encoding="utf-8") as f:
            existing = json.load(f).get("by_station", {})
        print(f"既存データ: {len(existing)}駅", file=sys.stderr)

    # タスク
    tasks = []
    for station in stations:
        name = station["station_name"]
        for year in years:
            if name in existing and str(year) in existing[name].get("years", {}):
                continue
            tasks.append((station, year))

    total_tasks = len(stations) * len(years)
    print(f"API呼び出し: {len(tasks)}件 (スキップ: {total_tasks - len(tasks)}件)",
          file=sys.stderr)

    if not tasks:
        print("全て取得済みです。", file=sys.stderr)
        return

    # 結果
    results: Dict[str, Any] = dict(existing)
    completed = 0
    errors = 0
    data_found = 0
    start_time = time.time()

    def worker(task):
        station, year = task
        return process_one(station, year, use_direct, api_key)

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {executor.submit(worker, t): t for t in tasks}

        for future in as_completed(futures):
            completed += 1
            try:
                result = future.result()
                if result:
                    name, code, yr, stats, quarterly, ward = result
                    data_found += 1
                    if name not in results:
                        station_info = next(
                            (s for s in stations if s["station_name"] == name), {}
                        )
                        results[name] = {
                            "group_code": code,
                            "years": {},
                            "quarters": {},
                            "ward": ward,
                            "lines": station_info.get("lines", []),
                            "operators": station_info.get("operators", []),
                            "tier": tiers.get(name, "Other"),
                        }
                    results[name]["years"][str(yr)] = stats
                    # 四半期データをマージ
                    if "quarters" not in results[name]:
                        results[name]["quarters"] = {}
                    results[name]["quarters"].update(quarterly)
                    if ward and not results[name].get("ward"):
                        results[name]["ward"] = ward
            except Exception:
                errors += 1

            if completed % 100 == 0 or completed == len(tasks):
                elapsed = time.time() - start_time
                rate = completed / elapsed if elapsed > 0 else 0
                eta = (len(tasks) - completed) / rate if rate > 0 else 0
                n_stations = sum(1 for r in results.values() if r.get("years"))
                print(
                    f"  [{completed:>5}/{len(tasks)}] "
                    f"{n_stations}駅 {data_found}年分取得 "
                    f"({rate:.1f}件/秒, 残{eta:.0f}秒) err={errors}",
                    file=sys.stderr,
                )

            if completed % 500 == 0:
                save_output(results, years)

    save_output(results, years)

    elapsed = time.time() - start_time
    n_stations = sum(1 for r in results.values() if r.get("years"))
    print(f"\n=== 完了 ===", file=sys.stderr)
    print(f"データあり: {n_stations}駅", file=sys.stderr)
    print(f"所要時間: {elapsed:.1f}秒 ({elapsed / 60:.1f}分)", file=sys.stderr)
    print(f"出力: {OUTPUT_FILE}", file=sys.stderr)


if __name__ == "__main__":
    main()
