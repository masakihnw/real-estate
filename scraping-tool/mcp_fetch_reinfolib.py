#!/usr/bin/env python3
"""
MCP streamable-HTTP クライアントで N-3 MCPサーバーから
不動産情報ライブラリの成約価格データを一括取得し、キャッシュJSONを構築する。

APIキー不要: MCPサーバーが内部でキーを保持している。

使い方:
    python3 mcp_fetch_reinfolib.py

出力:
    data/reinfolib_prices.json  — 区別m²単価中央値
    data/reinfolib_trends.json  — 区別四半期推移
"""

import json
import os
import statistics
import sys
import time
import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import requests

# ---------------------------------------------------------------------------
# MCP サーバー設定
# ---------------------------------------------------------------------------

MCP_URL = "https://mcp.n-3.ai/mcp"
MCP_PARAMS = {"tools": "reinfolib-real-estate-price,reinfolib-city-list"}
TOOL_NAME = "reinfolib-real-estate-price"

# ---------------------------------------------------------------------------
# 対象エリア
# ---------------------------------------------------------------------------

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

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "data")


# ---------------------------------------------------------------------------
# MCP プロトコル
# ---------------------------------------------------------------------------

class MCPClient:
    """Minimal MCP streamable-HTTP client."""

    def __init__(self, base_url: str, params: dict):
        self.url = base_url
        self.params = params
        self.session = requests.Session()
        self.session.headers.update({
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        })
        self._request_id = 0
        self._session_id: Optional[str] = None

    def _next_id(self) -> int:
        self._request_id += 1
        return self._request_id

    def _post(self, payload: dict) -> dict:
        """Send JSON-RPC request and parse response."""
        headers = {}
        if self._session_id:
            headers["Mcp-Session-Id"] = self._session_id

        resp = self.session.post(
            self.url,
            params=self.params,
            json=payload,
            headers=headers,
            timeout=120,
        )

        # Store session ID from response
        sid = resp.headers.get("Mcp-Session-Id")
        if sid:
            self._session_id = sid

        content_type = resp.headers.get("Content-Type", "")

        # SSE レスポンスの場合、encoding が latin-1 にフォールバックしてしまうことがあるので
        # 明示的に UTF-8 でデコード
        if "text/event-stream" in content_type:
            text = resp.content.decode("utf-8")
            return self._parse_sse(text)
        else:
            resp.encoding = "utf-8"
            return resp.json()

    def _parse_sse(self, text: str) -> dict:
        """Parse SSE response to extract JSON-RPC result."""
        result = None
        for line in text.split("\n"):
            line = line.strip()
            if line.startswith("data: "):
                data_str = line[6:]
                try:
                    data = json.loads(data_str)
                    if "result" in data or "error" in data:
                        result = data
                except json.JSONDecodeError:
                    pass
        return result or {}

    def initialize(self) -> dict:
        """Send MCP initialize handshake."""
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {
                    "name": "reinfolib-cache-builder",
                    "version": "1.0.0",
                },
            },
        }
        result = self._post(payload)
        print(f"MCP初期化完了: {json.dumps(result, ensure_ascii=False)[:200]}", file=sys.stderr)

        # Send initialized notification
        notif = {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        }
        try:
            self.session.post(
                self.url,
                params=self.params,
                json=notif,
                headers={"Mcp-Session-Id": self._session_id} if self._session_id else {},
                timeout=10,
            )
        except Exception:
            pass

        return result

    def call_tool(self, tool_name: str, arguments: dict) -> Optional[dict]:
        """Call an MCP tool and return the result."""
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "tools/call",
            "params": {
                "name": tool_name,
                "arguments": arguments,
            },
        }
        try:
            result = self._post(payload)
            if "error" in result:
                print(f"  ツールエラー: {result['error']}", file=sys.stderr)
                return None
            # Result content is in result.result.content[0].text
            content = result.get("result", {}).get("content", [])
            if content and len(content) > 0:
                text = content[0].get("text", "{}")
                return json.loads(text)
            return result.get("result")
        except Exception as e:
            print(f"  リクエスト例外: {e}", file=sys.stderr)
            return None


# ---------------------------------------------------------------------------
# データ取得
# ---------------------------------------------------------------------------

def fetch_all_ward_data(
    client: MCPClient,
    quarters: List[Tuple[str, str]],  # [(year, quarter), ...]
    price_classification: str = "02",
) -> Dict[str, Dict[str, List[dict]]]:
    """
    全23区 × 指定四半期のデータを取得。

    Returns: {ward_name: {quarter_label: [items...]}}
    """
    all_data: Dict[str, Dict[str, List[dict]]] = {}

    total_calls = len(WARD_CODE_TO_NAME) * len(quarters)
    done = 0

    for ward_code, ward_name in WARD_CODE_TO_NAME.items():
        all_data[ward_name] = {}

        for year_str, quarter_str in quarters:
            qlabel = f"{year_str}Q{quarter_str}"
            done += 1
            print(f"  [{done}/{total_calls}] {ward_name} {qlabel} ...", file=sys.stderr, end="")

            result = client.call_tool(TOOL_NAME, {
                "city": ward_code,
                "year": year_str,
                "quarter": quarter_str,
                "priceClassification": price_classification,
                "language": "ja",
                "limit": 100,
            })

            if result and "data" in result:
                items = result["data"]
                # 中古マンション等のみフィルタ
                mansion_items = [
                    item for item in items
                    if "中古マンション" in item.get("Type", "")
                ]
                all_data[ward_name][qlabel] = mansion_items
                print(f" {len(mansion_items)}件", file=sys.stderr)
            else:
                all_data[ward_name][qlabel] = []
                print(f" 0件", file=sys.stderr)

            # レート制限を考慮して少し待つ
            time.sleep(0.5)

    return all_data


# ---------------------------------------------------------------------------
# キャッシュ構築
# ---------------------------------------------------------------------------

def parse_m2_price(item: dict) -> Optional[float]:
    """m²単価を算出。"""
    try:
        price = float(str(item.get("TradePrice", "0")).replace(",", ""))
        area = float(str(item.get("Area", "0")).replace(",", ""))
        if area > 0 and price > 0:
            return price / area
    except (ValueError, TypeError):
        pass
    return None


def build_cache(
    all_data: Dict[str, Dict[str, List[dict]]],
) -> Tuple[dict, dict]:
    """prices.json と trends.json を構築。"""

    # 全四半期ラベルを収集
    all_quarters = set()
    for wd in all_data.values():
        all_quarters.update(wd.keys())
    sorted_quarters = sorted(all_quarters)

    # 直近4四半期
    recent_quarters = sorted_quarters[-4:] if len(sorted_quarters) >= 4 else sorted_quarters

    # --- prices.json ---
    prices_by_ward = {}
    for ward_name, quarter_data in all_data.items():
        recent_m2 = []
        quarterly = {}

        for ql in recent_quarters:
            items = quarter_data.get(ql, [])
            m2_prices = [p for item in items if (p := parse_m2_price(item)) is not None]
            recent_m2.extend(m2_prices)
            if m2_prices:
                quarterly[ql] = {
                    "median_m2_price": round(statistics.median(m2_prices)),
                    "count": len(m2_prices),
                }

        ward_code = next((k for k, v in WARD_CODE_TO_NAME.items() if v == ward_name), "")
        prices_by_ward[ward_name] = {
            "ward_code": ward_code,
            "median_m2_price": round(statistics.median(recent_m2)) if recent_m2 else None,
            "mean_m2_price": round(statistics.mean(recent_m2)) if recent_m2 else None,
            "sample_count": len(recent_m2),
            "quarterly": quarterly,
        }

    prices = {
        "by_ward": prices_by_ward,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "periods_covered": recent_quarters,
        "data_source": "不動産情報ライブラリ（国土交通省）",
    }

    # --- trends.json ---
    trends_by_ward = {}
    for ward_name, quarter_data in all_data.items():
        quarters_data = []
        for ql in sorted_quarters:
            items = quarter_data.get(ql, [])
            m2_prices = [p for item in items if (p := parse_m2_price(item)) is not None]
            entry = {
                "quarter": ql,
                "median_m2_price": round(statistics.median(m2_prices)) if m2_prices else None,
                "mean_m2_price": round(statistics.mean(m2_prices)) if m2_prices else None,
                "count": len(m2_prices),
            }
            quarters_data.append(entry)

        # YoY
        for i, qd in enumerate(quarters_data):
            if i >= 4 and qd["median_m2_price"] and quarters_data[i - 4]["median_m2_price"]:
                prev = quarters_data[i - 4]["median_m2_price"]
                curr = qd["median_m2_price"]
                qd["yoy_change_pct"] = round((curr - prev) / prev * 100, 1)
            else:
                qd["yoy_change_pct"] = None

        ward_code = next((k for k, v in WARD_CODE_TO_NAME.items() if v == ward_name), "")
        trends_by_ward[ward_name] = {
            "ward_code": ward_code,
            "quarters": quarters_data,
        }

    trends = {
        "by_ward": trends_by_ward,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "periods": sorted_quarters,
        "data_source": "不動産情報ライブラリ（国土交通省）",
    }

    return prices, trends


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main():
    print("=== MCP経由 不動産情報ライブラリ キャッシュ構築 ===", file=sys.stderr)

    client = MCPClient(MCP_URL, MCP_PARAMS)

    # 1. MCP初期化
    print("MCPサーバーに接続中...", file=sys.stderr)
    client.initialize()

    # 2. 取得対象の四半期を決定
    # 直近8四半期（2年分）を取得 → トレンドチャート用 + YoY比較用
    quarters = []
    for year in [2024, 2025]:
        for q in range(1, 5):
            # 2026年以降の未来四半期はスキップ
            if year == 2025 and q > 3:
                continue
            quarters.append((str(year), str(q)))

    print(f"対象四半期: {[f'{y}Q{q}' for y, q in quarters]}", file=sys.stderr)

    # 3. 成約価格データ取得
    print("\n成約価格データを取得中...", file=sys.stderr)
    all_data = fetch_all_ward_data(client, quarters, price_classification="02")

    # 4. キャッシュ構築
    print("\nキャッシュを構築中...", file=sys.stderr)
    prices, trends = build_cache(all_data)

    # 5. 保存
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    prices_path = os.path.join(OUTPUT_DIR, "reinfolib_prices.json")
    trends_path = os.path.join(OUTPUT_DIR, "reinfolib_trends.json")

    with open(prices_path, "w", encoding="utf-8") as f:
        json.dump(prices, f, ensure_ascii=False, indent=2)
    print(f"\n✓ prices キャッシュ保存: {prices_path}", file=sys.stderr)

    with open(trends_path, "w", encoding="utf-8") as f:
        json.dump(trends, f, ensure_ascii=False, indent=2)
    print(f"✓ trends キャッシュ保存: {trends_path}", file=sys.stderr)

    # サマリー
    ward_count = len(prices["by_ward"])
    total_samples = sum(w.get("sample_count", 0) for w in prices["by_ward"].values())
    print(f"\n=== 完了: {ward_count}区, 合計 {total_samples} サンプル ===", file=sys.stderr)

    # 各区のサマリーを表示
    print("\n区別m²単価中央値:", file=sys.stderr)
    for ward_name, data in sorted(prices["by_ward"].items(), key=lambda x: x[1].get("median_m2_price") or 0, reverse=True):
        median = data.get("median_m2_price")
        count = data.get("sample_count", 0)
        if median:
            print(f"  {ward_name}: {median:,.0f}円/m² ({count}件)", file=sys.stderr)
        else:
            print(f"  {ward_name}: データなし", file=sys.stderr)


if __name__ == "__main__":
    main()
