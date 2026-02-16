"""
HOME'S（LIFULL HOME'S）新築マンション一覧のスクレイピング。
利用規約: terms-check.md を参照。

一覧URL: https://www.homes.co.jp/mansion/shinchiku/tokyo/list/
ページング: ?page=N

新築は棟単位の情報。中古スクレイパーと同じ config.py フィルタを適用するが、
新築固有のロジック（価格未定の許容、間取り幅マッチ、築年フィルタ不要など）に対応。
"""

import json
import re
import sys
import time
from dataclasses import dataclass, asdict
from typing import Any, Iterator, Optional
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

from config import (
    PRICE_MIN_MAN,
    PRICE_MAX_MAN,
    AREA_MIN_M2,
    AREA_MAX_M2,
    WALK_MIN_MAX,
    TOTAL_UNITS_MIN,
    HOMES_REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
    REQUEST_RETRIES,
)
from parse_utils import parse_price_range, parse_area_range, parse_walk_min_best, parse_total_units, parse_floor_total_lenient, parse_ownership, parse_ownership_from_text, layout_range_ok
from report_utils import clean_listing_name
from scraper_common import create_session, is_waf_challenge, load_station_passengers, station_passengers_ok, line_ok, is_tokyo_23_by_address

BASE_URL = "https://www.homes.co.jp"

# 新築マンション一覧URL
LIST_URL_FIRST = "https://www.homes.co.jp/mansion/shinchiku/tokyo/list/"
LIST_URL_PAGE = "https://www.homes.co.jp/mansion/shinchiku/tokyo/list/?page={page}"
HOMES_SHINCHIKU_MAX_PAGES_SAFETY = 100

# 早期打ち切り: 連続 N ページで新規通過0件なら残りをスキップ
HOMES_SHINCHIKU_EARLY_EXIT_PAGES = 20

# スクレイピング全体のタイムリミット（秒）。HOME'S は WAF が厳しいため制限する。
HOMES_SHINCHIKU_SCRAPE_TIMEOUT_SEC = 30 * 60  # 30分


@dataclass
class HomesShinchikuListing:
    """HOME'S 新築マンション一覧から得た1件分（棟単位）。"""

    source: str = "homes"
    property_type: str = "shinchiku"
    url: str = ""
    name: str = ""
    price_man: Optional[int] = None
    price_max_man: Optional[int] = None
    address: str = ""
    station_line: str = ""
    walk_min: Optional[int] = None
    area_m2: Optional[float] = None
    area_max_m2: Optional[float] = None
    layout: str = ""
    delivery_date: str = ""
    total_units: Optional[int] = None
    floor_total: Optional[int] = None
    list_ward_roman: Optional[str] = None

    # 中古互換用
    built_str: str = ""
    built_year: Optional[int] = None
    floor_position: Optional[int] = None
    floor_structure: Optional[str] = None
    ownership: Optional[str] = None

    def to_dict(self):
        return asdict(self)


# ---------- ページ取得 ----------


def fetch_list_page(session: requests.Session, url: str) -> str:
    """一覧ページのHTMLを取得。5xx/429/WAF/タイムアウト・接続エラー時はリトライする。"""
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES + 2):  # WAF 対策で追加リトライ
        time.sleep(HOMES_REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            # 429 Too Many Requests — レートリミット対策
            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                print(f"  429 Rate Limited, waiting {retry_after}s (attempt {attempt + 1})", file=sys.stderr)
                time.sleep(retry_after)
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            html = r.text
            # AWS WAF チャレンジページの検出
            if is_waf_challenge(html):
                wait = min(30 * (attempt + 1), 120)
                print(f"  WAF challenge detected, waiting {wait}s (attempt {attempt + 1})", file=sys.stderr)
                time.sleep(wait)
                continue
            return html
        except requests.exceptions.HTTPError as e:
            if e.response is not None and e.response.status_code in (500, 502, 503) and attempt < REQUEST_RETRIES - 1:
                last_error = e
                time.sleep(2)
            else:
                raise
        except (requests.exceptions.ReadTimeout, requests.exceptions.ConnectTimeout, requests.exceptions.ConnectionError) as e:
            last_error = e
            if attempt < REQUEST_RETRIES - 1:
                time.sleep(2)
    if last_error is not None:
        raise last_error
    raise RuntimeError(f"全リトライが失敗しました (WAF/Rate Limited): {url}")


# ---------- HTMLパース ----------

def _parse_jsonld_itemlist(html: str) -> list[dict[str, Any]]:
    """JSON-LD の ItemList からデータを抽出（HOME'S 新築にも JSON-LD があれば利用）。"""
    soup = BeautifulSoup(html, "lxml")
    for script in soup.find_all("script", type="application/ld+json"):
        raw = script.string
        if not raw or "itemListElement" not in (raw or ""):
            continue
        try:
            data = json.loads(raw)
            if data.get("@type") != "ItemList" or "itemListElement" not in data:
                continue
            out = []
            for el in data["itemListElement"]:
                item = el.get("item") or el
                if not isinstance(item, dict):
                    continue
                name = (item.get("name") or "").strip()
                url = (item.get("url") or "").strip()
                if not url:
                    continue
                offer = item.get("offers") or {}
                if isinstance(offer, list):
                    offer = offer[0] if offer else {}
                price = offer.get("price")
                price_man = int(price) // 10000 if price is not None else None
                io = offer.get("itemOffered") or {}
                fs = io.get("floorSize") or {}
                area_m2 = float(fs["value"]) if fs.get("value") is not None else None
                addr = io.get("address") or {}
                address = (addr.get("name") or "").strip()
                out.append({
                    "url": url,
                    "name": name,
                    "price_man": price_man,
                    "area_m2": area_m2,
                    "address": address,
                })
            return out
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            continue
    return []


def _extract_card_listings(soup: BeautifulSoup) -> list[HomesShinchikuListing]:
    """2026年リニューアル後のカード型一覧からパース。
    各物件はテーブル（価格/間取り/所在地/専有面積/交通/完成予定）を含むブロック。
    """
    items: list[HomesShinchikuListing] = []
    seen_urls: set[str] = set()

    # 物件詳細リンク /mansion/b-{id}/ を探す
    detail_links = soup.find_all("a", href=re.compile(r"/mansion/b-\d+/?$"))
    for link in detail_links:
        href = link.get("href", "")
        url = urljoin(BASE_URL, href)
        if url in seen_urls:
            continue
        # 物件ブロックを探す: リンクを含む最も近いコンテナ
        container = link
        for _ in range(15):
            container = container.parent
            if container is None or container.name in ("body", "html", "[document]"):
                container = None
                break
            text = container.get_text() or ""
            if ("所在地" in text and "交通" in text) or ("所在地" in text and "完成" in text):
                if container.find("table") or container.find(["dt", "th"]):
                    break
        if container is None:
            continue
        seen_urls.add(url)

        text = container.get_text(separator="\n")

        # 物件名: h2/h3/h4
        name = ""
        for tag in ("h2", "h3", "h4"):
            el = container.find(tag)
            if el:
                raw = (el.get_text(strip=True) or "").strip()
                # 「新築マンション」「分譲予定」などのプレフィックスを除去
                raw = re.sub(r"^(?:新築)?マンション\s*分譲(?:予定|中)?\s*", "", raw).strip()
                # 共通クリーニング: 先頭「マンション」「新築マンション」、末尾「閲覧済」等を除去
                cleaned = clean_listing_name(raw)
                if cleaned:
                    name = cleaned
                    break

        # h2/h3/h4 で物件名が取得できなかった場合（「掲載物件X件」等）、
        # 物件詳細リンクのテキストから取得を試みる
        if not name:
            for a in container.find_all("a", href=re.compile(r"/mansion/b-\d+")):
                t = (a.get_text(strip=True) or "").strip()
                cleaned = clean_listing_name(t) if t else ""
                if cleaned and "詳細" not in cleaned and "資料" not in cleaned and len(cleaned) >= 3:
                    name = cleaned
                    break

        # テーブルからの情報抽出
        def _table_value(label: str) -> str:
            for tbl in container.find_all("table"):
                for tr in tbl.find_all("tr"):
                    ths = tr.find_all(["th", "dt"])
                    tds = tr.find_all(["td", "dd"])
                    for i, th in enumerate(ths):
                        if label in (th.get_text() or ""):
                            if i < len(tds):
                                return (tds[i].get_text(strip=True) or "").strip()
            dt = container.find(["dt", "th"], string=re.compile(re.escape(label)))
            if dt:
                sibling = dt.find_next_sibling(["dd", "td"])
                if sibling:
                    return (sibling.get_text(strip=True) or "").strip()
            return ""

        # テーブルの「物件名」からも取得を試みる（h2/h3/h4 でダメだった場合のフォールバック）
        if not name:
            table_name = _table_value("物件名")
            if table_name:
                cleaned = clean_listing_name(table_name)
                if cleaned:
                    name = cleaned

        address = _table_value("所在地")
        station_line = _table_value("交通")
        layout = _table_value("間取り") or _table_value("間取")
        # 「一般販売住戸：」等のプレフィックスを除去
        layout = re.sub(r"^一般販売住戸[：:]\s*", "", layout).strip()
        area_str = _table_value("専有面積") or _table_value("面積")
        area_str = re.sub(r"^一般販売住戸[：:]\s*", "", area_str).strip()
        price_str = _table_value("価格")
        price_str = re.sub(r"^一般販売住戸[：:]\s*", "", price_str).strip()
        delivery_date = _table_value("完成予定") or _table_value("完成") or _table_value("引渡")

        price_man, price_max_man = parse_price_range(price_str) if price_str else (None, None)
        area_m2, area_max_m2 = parse_area_range(area_str) if area_str else (None, None)
        walk_min = parse_walk_min_best(station_line or text)
        total_units = parse_total_units(text)
        floor_total = parse_floor_total_lenient(text)

        # 権利形態
        ownership_raw = _table_value("権利形態") or _table_value("敷地の権利形態") or _table_value("権利")
        ownership = parse_ownership(ownership_raw) if ownership_raw else None
        if not ownership:
            ownership = parse_ownership_from_text(text)

        if not name and not url:
            continue

        items.append(HomesShinchikuListing(
            url=url,
            name=name,
            price_man=price_man,
            price_max_man=price_max_man,
            address=address,
            station_line=station_line,
            walk_min=walk_min,
            area_m2=area_m2,
            area_max_m2=area_max_m2,
            layout=layout,
            delivery_date=delivery_date,
            total_units=total_units,
            floor_total=floor_total,
            ownership=ownership or None,
        ))
    return items


def parse_list_html(html: str) -> list[HomesShinchikuListing]:
    """HOME'S 新築マンション一覧HTMLから物件リストをパース。
    2026年リニューアル後はカード型パーサーにフォールバック。"""
    soup = BeautifulSoup(html, "lxml")
    items: list[HomesShinchikuListing] = []

    # JSON-LD があればベースデータとして使用
    jsonld_items = _parse_jsonld_itemlist(html)

    # HTML パース: 新築ページ固有のブロック（旧構造）
    # HOME'S 新築は mod-mergeBuilding--new や mod-buildingSummary 等のクラスを使う可能性
    for block in soup.find_all(["div", "section", "li"], class_=True):
        text = block.get_text()
        # 新築マンションのブロックを判定: 物件名リンク + 所在地 + 交通
        if not ("所在地" in text and "交通" in text):
            continue
        # 二重計上防止: ブロック内にネストした同条件ブロックがあれば内側を使う
        inner = block.find_all(["div", "section", "li"], class_=True)
        is_outer = any(
            "所在地" in (ib.get_text() or "") and "交通" in (ib.get_text() or "")
            for ib in inner if ib is not block
        )
        if is_outer:
            continue

        listing = _parse_homes_block(block)
        if listing and listing.name:
            items.append(listing)

    # 旧構造で0件、または大半が名前不明の場合、カード型パーサーを試行
    named_count = sum(1 for it in items if it.name and it.name != "（不明）")
    if not items or (items and named_count < len(items) * 0.5):
        card_items = _extract_card_listings(soup)
        if card_items:
            items = card_items

    # JSON-LD データで補完
    if jsonld_items:
        url_map = {item.url: item for item in items}
        for jd in jsonld_items:
            url = jd.get("url", "")
            if url in url_map:
                item = url_map[url]
                if item.price_man is None and jd.get("price_man"):
                    item.price_man = jd["price_man"]
                if not item.address and jd.get("address"):
                    item.address = jd["address"]
            elif url:
                items.append(HomesShinchikuListing(
                    url=url,
                    name=clean_listing_name(jd.get("name", "")),
                    price_man=jd.get("price_man"),
                    address=jd.get("address", ""),
                    area_m2=jd.get("area_m2"),
                ))

    return items


def _parse_homes_block(block) -> Optional[HomesShinchikuListing]:
    """1つの物件ブロックからデータを抽出。"""
    try:
        text = block.get_text(separator="\n")

        # 物件名
        name_el = block.find(["h2", "h3", "h4"])
        raw_name = (name_el.get_text(strip=True) or "").strip() if name_el else ""
        if not raw_name:
            a = block.find("a", href=True)
            if a:
                raw_name = (a.get_text(strip=True) or "").strip()
        name = clean_listing_name(raw_name)

        # URL
        url = ""
        a = block.find("a", href=re.compile(r"/mansion/"))
        if a:
            url = urljoin(BASE_URL, a.get("href", ""))

        # DT/DD or テキストパース
        def get_val(label: str) -> str:
            dt = block.find(["dt", "th"], string=re.compile(re.escape(label)))
            if dt:
                sibling = dt.find_next_sibling(["dd", "td"])
                if sibling:
                    return (sibling.get_text(strip=True) or "").strip()
            m = re.search(rf"{re.escape(label)}[：:\s]*([^\n]+)", text)
            return (m.group(1).strip() if m else "").strip()

        address = get_val("所在地")
        station_line = get_val("交通")
        delivery_date = get_val("引渡") or get_val("入居")
        walk_min = parse_walk_min_best(station_line or text)

        # 価格
        price_man, price_max_man = (None, None)
        for line in text.split("\n"):
            line = line.strip()
            if "万円" in line and "タイプ" not in line:
                price_man, price_max_man = parse_price_range(line)
                if price_man is not None:
                    break

        # 間取り / 面積
        layout = ""
        area_m2, area_max_m2 = None, None
        for line in text.split("\n"):
            line = line.strip()
            if re.search(r"[0-9LDKS]+.*[/／].*m2", line, re.I):
                parts = re.split(r"[/／]", line, maxsplit=1)
                layout = parts[0].strip()
                if len(parts) > 1:
                    area_m2, area_max_m2 = parse_area_range(parts[1])
                break

        total_units = parse_total_units(text)
        floor_total = parse_floor_total_lenient(text)

        # 権利形態
        ownership_raw = get_val("権利形態") or get_val("敷地の権利形態") or get_val("権利")
        ownership = parse_ownership(ownership_raw) if ownership_raw else None
        if not ownership:
            ownership = parse_ownership_from_text(text)

        return HomesShinchikuListing(
            url=url,
            name=name or "（不明）",
            price_man=price_man,
            price_max_man=price_max_man,
            address=address,
            station_line=station_line,
            walk_min=walk_min,
            area_m2=area_m2,
            area_max_m2=area_max_m2,
            layout=layout,
            delivery_date=delivery_date,
            total_units=total_units,
            floor_total=floor_total,
            ownership=ownership or None,
        )
    except Exception:
        return None


# ---------- フィルタ ----------


def apply_conditions(listings: list[HomesShinchikuListing]) -> list[HomesShinchikuListing]:
    """新築用フィルタ。"""
    passengers_map = load_station_passengers()
    out = []
    for r in listings:
        if not is_tokyo_23_by_address(r.address):
            continue
        if not line_ok(r.station_line):
            continue
        if not station_passengers_ok(r.station_line, passengers_map):
            continue
        if r.price_man is not None:
            price_hi = r.price_max_man or r.price_man
            if price_hi < PRICE_MIN_MAN or r.price_man > PRICE_MAX_MAN:
                continue
        area_hi = r.area_max_m2 or r.area_m2
        if area_hi is not None and area_hi < AREA_MIN_M2:
            continue
        if AREA_MAX_M2 is not None and r.area_m2 is not None and r.area_m2 > AREA_MAX_M2:
            continue
        if not layout_range_ok(r.layout):
            continue
        if r.walk_min is not None and r.walk_min > WALK_MIN_MAX:
            continue
        if r.total_units is not None and r.total_units < TOTAL_UNITS_MIN:
            continue
        out.append(r)
    return out


# ---------- メインエントリ ----------

def scrape_homes_shinchiku(max_pages: Optional[int] = 0, apply_filter: bool = True) -> Iterator[HomesShinchikuListing]:
    """HOME'S 新築マンション一覧を取得。max_pages=0 のときは全ページ取得。"""
    session = create_session()
    limit = max_pages if max_pages and max_pages > 0 else HOMES_SHINCHIKU_MAX_PAGES_SAFETY
    page = 1
    total_parsed = 0
    total_passed = 0
    pages_since_last_pass = 0  # 最後の通過からの連続ページ数（早期打ち切り用）
    start_time = time.monotonic()
    while page <= limit:
        # タイムリミットチェック（WAF 遅延でパイプライン全体がタイムアウトするのを防止）
        elapsed = time.monotonic() - start_time
        if elapsed > HOMES_SHINCHIKU_SCRAPE_TIMEOUT_SEC:
            print(f"HOME'S 新築: タイムリミット到達（{int(elapsed)}秒, {page - 1}ページ処理済, 通過: {total_passed}件）", file=sys.stderr)
            break
        url = LIST_URL_FIRST if page == 1 else LIST_URL_PAGE.format(page=page)
        try:
            html = fetch_list_page(session, url)
        except Exception as e:
            print(f"HOME'S 新築: ページ{page}でエラー: {e}", file=sys.stderr)
            break
        rows = parse_list_html(html)
        if not rows:
            print(f"HOME'S 新築: ページ{page}で0件パース。一覧のHTML構造が変わった可能性があります。", file=sys.stderr)
            break
        total_parsed += len(rows)
        passed = 0
        for row in rows:
            if apply_filter:
                filtered = apply_conditions([row])
                if filtered:
                    yield filtered[0]
                    passed += 1
                    _price = f"{filtered[0].price_man}万" if filtered[0].price_man else "価格未定"
                    print(f"  ✓ {filtered[0].name} ({_price})", file=sys.stderr)
            else:
                yield row
                passed += 1
        total_passed += passed
        # 早期打ち切り判定: 連続 N ページで新規通過0件なら中断
        if passed > 0:
            pages_since_last_pass = 0
        else:
            pages_since_last_pass += 1
        if pages_since_last_pass >= HOMES_SHINCHIKU_EARLY_EXIT_PAGES:
            print(f"HOME'S 新築: 早期打ち切り（{pages_since_last_pass}ページ連続で通過0件, 累計通過: {total_passed}件）", file=sys.stderr)
            break
        # 進捗: 10ページごとにサマリー
        if page % 10 == 0:
            print(f"HOME'S 新築: ...{page}ページ処理済 (通過: {total_passed}件)", file=sys.stderr)
        page += 1
    if total_parsed > 0:
        print(f"HOME'S 新築: 完了 — {total_parsed}件パース, {total_passed}件通過", file=sys.stderr)