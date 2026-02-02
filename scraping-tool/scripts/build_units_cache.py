#!/usr/bin/env python3
"""
SUUMO 物件詳細ページから総戸数を取得し、data/building_units.json にキャッシュする。
main.py の取得結果（results/latest.json）の SUUMO URL を対象に、詳細ページを取得して総戸数をパースする。
キャッシュがあると apply_conditions で総戸数100戸以上フィルタが有効になる。

使い方:
  python scripts/build_units_cache.py                    # results/latest.json の URL を対象
  python scripts/build_units_cache.py results/xxx.json  # 指定 JSON を対象
"""

import json
import re
import sys
import time
from pathlib import Path

import requests

# スクリプト配置が scraping-tool/ である前提
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from config import REQUEST_DELAY_SEC, REQUEST_TIMEOUT_SEC, REQUEST_RETRIES, USER_AGENT

CACHE_PATH = ROOT / "data" / "building_units.json"


def _parse_total_units_from_html(html: str) -> int | None:
    """HTML から総戸数を抽出。SUUMO 詳細ページの表・dt/dd などを想定。"""
    # 総戸数 123戸 や 総戸数：123戸 など
    m = re.search(r"総戸数\s*[：:]\s*(\d+)\s*戸", html)
    if m:
        return int(m.group(1))
    m = re.search(r"総戸数\s*(\d+)\s*戸", html)
    if m:
        return int(m.group(1))
    return None


def fetch_detail(session: requests.Session, url: str) -> str:
    """詳細ページの HTML を取得。"""
    session.headers["User-Agent"] = USER_AGENT
    for attempt in range(REQUEST_RETRIES):
        time.sleep(REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
        except (requests.exceptions.ReadTimeout, requests.exceptions.ConnectTimeout, requests.exceptions.ConnectionError) as e:
            if attempt < REQUEST_RETRIES - 1:
                time.sleep(2)
            else:
                raise e
    return ""


def main() -> None:
    json_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "results" / "latest.json"
    if not json_path.exists():
        print(f"対象ファイルがありません: {json_path}", file=sys.stderr)
        sys.exit(1)

    with open(json_path, "r", encoding="utf-8") as f:
        rows = json.load(f)

    suumo_urls = [r["url"] for r in rows if isinstance(r, dict) and r.get("source") == "suumo" and r.get("url")]
    if not suumo_urls:
        print("SUUMO の URL がありません。", file=sys.stderr)
        sys.exit(0)

    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    existing: dict[str, int] = {}
    if CACHE_PATH.exists():
        try:
            with open(CACHE_PATH, "r", encoding="utf-8") as f:
                existing = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    session = requests.Session()
    updated = 0
    for url in suumo_urls:
        if url in existing:
            continue
        try:
            html = fetch_detail(session, url)
            units = _parse_total_units_from_html(html)
            if units is not None:
                existing[url] = units
                updated += 1
                print(f"  {url[:60]}... → {units}戸", file=sys.stderr)
        except Exception as e:
            print(f"  取得失敗 {url[:50]}...: {e}", file=sys.stderr)

    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(existing, f, ensure_ascii=False, indent=2)
    print(f"キャッシュ保存: {CACHE_PATH} ({len(existing)}件、今回{updated}件追加)", file=sys.stderr)


if __name__ == "__main__":
    main()
