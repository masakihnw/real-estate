#!/usr/bin/env python3
"""
マンションレビュー（mansion-review.jp）から物件別の市場データを取得するスクレイパー。

取得データ:
  - 推定適正価格 / 推定坪単価 / 推定m²単価
  - マンション偏差値
  - 騰落率
  - 販売履歴件数
  - 過去の中古販売履歴テーブル（公開分）

使い方:
  python3 mansion_review_scraper.py --input results/latest.json --output results/latest.json

キャッシュ:
  data/mansion_review_cache.json — 物件名 → {building_url, data} のキャッシュ
"""

import argparse
import json
import os
import re
import sys
import time
import unicodedata
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from bs4 import BeautifulSoup

from config import REQUEST_DELAY_SEC

from logger import get_logger
logger = get_logger(__name__)

SCRIPT_DIR = Path(__file__).resolve().parent
CACHE_PATH = SCRIPT_DIR / "data" / "mansion_review_cache.json"
CACHE_TTL_DAYS = 14

BASE_URL = "https://www.mansion-review.jp"
SEARCH_URL = f"{BASE_URL}/keyword_search/"

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)

DELAY = max(REQUEST_DELAY_SEC, 3.0)


def _normalize_name(name: str) -> str:
    """物件名を正規化（NFKC + 空白除去）。"""
    s = unicodedata.normalize("NFKC", name)
    s = re.sub(r"\s+", "", s)
    return s


def load_cache() -> dict:
    if CACHE_PATH.exists():
        return json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    return {}


def save_cache(cache: dict) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    CACHE_PATH.write_text(
        json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def _is_cache_valid(entry: dict) -> bool:
    """キャッシュエントリの有効期限を確認。"""
    cached_at = entry.get("cached_at")
    if not cached_at:
        return False
    try:
        cached_date = datetime.fromisoformat(cached_at)
        return datetime.now() - cached_date < timedelta(days=CACHE_TTL_DAYS)
    except (ValueError, TypeError):
        return False


def _make_session() -> requests.Session:
    session = requests.Session()
    session.headers.update({
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "ja,en-US;q=0.7,en;q=0.3",
    })
    return session


def search_building(
    session: requests.Session, name: str
) -> Optional[str]:
    """
    マンション名でマンションレビューを検索し、建物ページ URL を返す。
    見つからなければ None。
    """
    params = {"free_text": name}
    try:
        resp = session.get(
            SEARCH_URL, params=params, timeout=30, allow_redirects=True
        )
        if resp.status_code != 200:
            logger.error(f"  検索エラー: {resp.status_code} ({name})",
                file=sys.stderr,
            )
            return None

        soup = BeautifulSoup(resp.text, "html.parser")

        # 直接建物ページにリダイレクトされた場合
        if "/mansion/" in resp.url and resp.url.endswith(".html"):
            return resp.url

        # 検索結果からリンクを探す
        for a_tag in soup.select("a[href*='/mansion/']"):
            href = a_tag.get("href", "")
            if re.match(r"/mansion/\d+\.html", href):
                return BASE_URL + href
            if re.match(
                r"https://www\.mansion-review\.jp/mansion/\d+\.html", href
            ):
                return href

    except Exception as e:
        print(f"  検索例外: {name} — {e}")

    return None


def parse_building_page(
    session: requests.Session, url: str
) -> Optional[Dict[str, Any]]:
    """
    建物ページから公開データをパースする。
    """
    try:
        resp = session.get(url, timeout=30)
        if resp.status_code != 200:
            return None
    except Exception as e:
        logger.error(f"  ページ取得エラー: {url} — {e}")
        return None

    soup = BeautifulSoup(resp.text, "html.parser")
    data: Dict[str, Any] = {"building_url": url}

    # マンション偏差値
    deviation = _extract_deviation_score(soup)
    if deviation is not None:
        data["deviation_score"] = deviation

    # 推定相場
    estimated = _extract_estimated_prices(soup)
    data.update(estimated)

    # 騰落率
    touraku = _extract_touraku_rate(soup)
    if touraku is not None:
        data["touraku_rate"] = touraku

    # 販売履歴件数
    history_counts = _extract_history_counts(soup)
    data.update(history_counts)

    # 中古販売履歴テーブル（公開分）
    sales_history = _extract_sales_history_table(soup)
    if sales_history:
        data["sales_history"] = sales_history

    return data


def _extract_deviation_score(soup: BeautifulSoup) -> Optional[int]:
    """マンション偏差値を抽出。"""
    text = soup.get_text()
    m = re.search(r"マンション偏差値[^\d]*(\d{1,2})", text)
    if m:
        return int(m.group(1))
    return None


def _extract_estimated_prices(soup: BeautifulSoup) -> dict:
    """推定適正価格・坪単価・m²単価を抽出。"""
    result = {}
    text = soup.get_text()

    m = re.search(r"推定適正価格[^\d]*([\d,]+)\s*万円", text)
    if m:
        result["estimated_price_man"] = int(m.group(1).replace(",", ""))

    m = re.search(r"推定相場坪単価[^\d]*([\d,]+)\s*万円/坪", text)
    if m:
        result["estimated_tsubo_price_man"] = int(m.group(1).replace(",", ""))

    m = re.search(r"推定相場㎡単価[^\d]*([\d,]+)\s*万円/㎡", text)
    if m:
        result["estimated_m2_price_man"] = int(m.group(1).replace(",", ""))

    return result


def _extract_touraku_rate(soup: BeautifulSoup) -> Optional[float]:
    """騰落率を抽出。"""
    text = soup.get_text()
    m = re.search(r"騰落率[^\d\-+]*([+\-]?\d+\.?\d*)\s*%", text)
    if m:
        return float(m.group(1))
    return None


def _extract_history_counts(soup: BeautifulSoup) -> dict:
    """販売履歴・賃料履歴の件数を抽出。"""
    result = {}
    text = soup.get_text()

    m = re.search(r"新築時:(\d+)件\s*中古:(\d+)件", text)
    if m:
        result["shinchiku_history_count"] = int(m.group(1))
        result["chuko_history_count"] = int(m.group(2))

    m = re.search(r"賃料履歴[^\d]*(\d+)件", text)
    if m:
        result["rental_history_count"] = int(m.group(1))

    return result


def _extract_sales_history_table(soup: BeautifulSoup) -> List[dict]:
    """
    中古販売履歴テーブルから公開されているレコードを抽出。
    ログインなしでは一部のみ表示される。
    """
    records: List[dict] = []

    # テーブルヘッダを見つける
    for table in soup.find_all("table"):
        headers = [th.get_text(strip=True) for th in table.find_all("th")]
        if not any("販売" in h or "価格" in h for h in headers):
            continue

        for row in table.find_all("tr"):
            cols = row.find_all("td")
            if len(cols) < 4:
                continue

            col_texts = [c.get_text(strip=True) for c in cols]

            # モザイクされたデータはスキップ
            if any("会員登録" in t or "モザイク" in t for t in col_texts):
                continue

            record = _parse_history_row(col_texts, headers)
            if record and record.get("price_man"):
                records.append(record)

    return records


def _parse_history_row(cols: List[str], headers: List[str]) -> Optional[dict]:
    """販売履歴テーブルの1行をパース。"""
    record: Dict[str, Any] = {}

    for i, header in enumerate(headers):
        if i >= len(cols):
            break
        val = cols[i]

        if "販売開始" in header:
            record["start_date"] = val
        elif "販売終了" in header:
            record["end_date"] = val
        elif "所在階" in header:
            m = re.search(r"(\d+)", val)
            if m:
                record["floor"] = int(m.group(1))
        elif "間取り" in header:
            record["layout"] = val
        elif "専有面積" in header:
            m = re.search(r"([\d.]+)", val)
            if m:
                record["area_m2"] = float(m.group(1))
        elif "価格" in header and "坪" not in header and "㎡" not in header:
            m = re.search(r"([\d,]+)\s*万", val)
            if m:
                record["price_man"] = int(m.group(1).replace(",", ""))
        elif "坪単価" in header:
            m = re.search(r"([\d,.]+)\s*万", val)
            if m:
                record["tsubo_price_man"] = float(m.group(1).replace(",", ""))

    return record if record else None


def enrich_single(
    session: requests.Session,
    name: str,
    cache: dict,
) -> Optional[Dict[str, Any]]:
    """
    1物件分のマンションレビューデータを取得。
    キャッシュ有効ならキャッシュを返す。
    """
    key = _normalize_name(name)

    if key in cache:
        entry = cache[key]
        if isinstance(entry, dict) and _is_cache_valid(entry):
            return entry.get("data")
        if entry is None:
            return None

    time.sleep(DELAY)

    url = search_building(session, name)
    if not url:
        cache[key] = {"data": None, "cached_at": datetime.now().isoformat()}
        return None

    time.sleep(DELAY)

    data = parse_building_page(session, url)
    if data:
        cache[key] = {
            "data": data,
            "cached_at": datetime.now().isoformat(),
        }
        return data
    else:
        cache[key] = {"data": None, "cached_at": datetime.now().isoformat()}
        return None


def enrich_listings(
    input_path: str,
    output_path: str,
    retry_not_found: bool = False,
    max_time_min: int = 0,
) -> None:
    """
    物件リストにマンションレビューのデータを付与。
    """
    with open(input_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    cache = load_cache()
    session = _make_session()

    deadline = time.time() + max_time_min * 60 if max_time_min > 0 else None

    if retry_not_found:
        keys_to_remove = [
            k for k, v in cache.items()
            if isinstance(v, dict) and v.get("data") is None
        ]
        for k in keys_to_remove:
            del cache[k]
        print(
            f"not-found キャッシュ {len(keys_to_remove)} 件クリア",
            file=sys.stderr,
        )

    enriched = 0
    skipped = 0
    timed_out = 0
    total = len(listings)

    for i, listing in enumerate(listings):
        if listing.get("mansion_review_data"):
            skipped += 1
            continue

        name = listing.get("name", "")
        if not name:
            continue

        if deadline and time.time() > deadline:
            timed_out = total - i
            print(
                f"  [{i + 1}/{total}] 残り{timed_out}件: 時間切れ（{max_time_min}分）",
                file=sys.stderr,
            )
            break

        data = enrich_single(session, name, cache)

        if data:
            listing["mansion_review_data"] = json.dumps(
                data, ensure_ascii=False
            )
            enriched += 1
            print(
                f"  [{i + 1}/{total}] {name}: 取得成功",
                file=sys.stderr,
            )
        else:
            print(
                f"  [{i + 1}/{total}] {name}: 該当なし",
                file=sys.stderr,
            )

        if (i + 1) % 10 == 0:
            save_cache(cache)

    save_cache(cache)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)

    timeout_msg = f", タイムアウト: {timed_out}" if timed_out else ""
    print(
        f"\nマンションレビュー enrichment 完了: "
        f"{enriched}/{total} 件取得 (スキップ: {skipped}{timeout_msg})",
        file=sys.stderr,
    )


def main() -> None:
    ap = argparse.ArgumentParser(
        description="マンションレビューから物件データを取得・付与"
    )
    ap.add_argument("--input", required=True, help="入力JSONファイル")
    ap.add_argument("--output", required=True, help="出力JSONファイル")
    ap.add_argument(
        "--retry-not-found",
        action="store_true",
        help="前回該当なしだった物件を再検索",
    )
    ap.add_argument(
        "--max-time",
        type=int,
        default=0,
        help="最大実行時間（分）。0=無制限",
    )
    args = ap.parse_args()
    enrich_listings(args.input, args.output, args.retry_not_found, args.max_time)


if __name__ == "__main__":
    main()
