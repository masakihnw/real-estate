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
from pathlib import Path
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
    STATION_PASSENGERS_MIN,
    ALLOWED_LINE_KEYWORDS,
    REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
    REQUEST_RETRIES,
    USER_AGENT,
    TOKYO_23_WARDS,
)

BASE_URL = "https://www.homes.co.jp"

# 新築マンション一覧URL
LIST_URL_FIRST = "https://www.homes.co.jp/mansion/shinchiku/tokyo/list/"
LIST_URL_PAGE = "https://www.homes.co.jp/mansion/shinchiku/tokyo/list/?page={page}"
HOMES_SHINCHIKU_MAX_PAGES_SAFETY = 100


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


def _session() -> requests.Session:
    s = requests.Session()
    s.headers["User-Agent"] = USER_AGENT
    s.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    s.headers["Accept-Language"] = "ja,en;q=0.9"
    return s


# ---------- パース補助関数 ----------

def _parse_price_range(text: str) -> tuple[Optional[int], Optional[int]]:
    """価格帯をパース。suumo_shinchiku_scraper と同じロジック。"""
    if not text or "価格未定" in text:
        return (None, None)
    text = text.replace(",", "").replace("（", "(").replace("）", ")")
    text = re.sub(r"\(.*?\)", "", text).strip()
    text = re.sub(r"[／/]\s*予定", "", text).strip()

    def _single(s: str) -> Optional[int]:
        s = s.strip()
        if not s:
            return None
        if "億" in s:
            m = re.search(r"([0-9.]+)\s*億\s*([0-9.]*)\s*万?円?\s*台?", s)
            if m:
                return int(float(m.group(1)) * 10000 + float(m.group(2) or 0))
        m = re.search(r"([0-9.,]+)\s*万\s*円?\s*台?", s)
        return int(float(m.group(1).replace(",", ""))) if m else None

    parts = re.split(r"[～〜]", text, maxsplit=1)
    if len(parts) == 2:
        return (_single(parts[0]), _single(parts[1]))
    val = _single(text)
    return (val, val)


def _parse_area_range(text: str) -> tuple[Optional[float], Optional[float]]:
    if not text:
        return (None, None)
    vals = re.findall(r"([0-9.]+)\s*(?:m2|㎡|m\s*2)", text, re.I)
    if len(vals) >= 2:
        return (float(vals[0]), float(vals[1]))
    elif len(vals) == 1:
        return (float(vals[0]), float(vals[0]))
    return (None, None)


def _parse_walk_min(text: str) -> Optional[int]:
    if not text:
        return None
    vals = re.findall(r"徒歩\s*約?\s*([0-9]+)\s*分", text)
    return min(int(v) for v in vals) if vals else None


def _parse_total_units(text: str) -> Optional[int]:
    if not text:
        return None
    m = re.search(r"(?:全|総戸数\s*)(\d+)\s*(?:邸|戸)", text)
    return int(m.group(1)) if m else None


def _parse_floor_total(text: str) -> Optional[int]:
    if not text:
        return None
    m = re.search(r"(?:地上\s*)?(\d+)\s*階(?:\s*建)?", text)
    return int(m.group(1)) if m else None


# ---------- ページ取得 ----------

def fetch_list_page(session: requests.Session, url: str) -> str:
    """一覧ページのHTMLを取得。5xx/429/タイムアウト・接続エラー時はリトライする。"""
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            # 429 Too Many Requests — レートリミット対策
            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                print(f"  429 Rate Limited, waiting {retry_after}s (attempt {attempt + 1}/{REQUEST_RETRIES})", file=sys.stderr)
                time.sleep(retry_after)
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
        except requests.exceptions.HTTPError as e:
            # 500/502/503 は一時的なサーバーエラーのためリトライ
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
    raise RuntimeError(f"全 {REQUEST_RETRIES} 回のリトライが失敗しました (429 Rate Limited): {url}")


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


def parse_list_html(html: str) -> list[HomesShinchikuListing]:
    """HOME'S 新築マンション一覧HTMLから物件リストをパース。"""
    soup = BeautifulSoup(html, "lxml")
    items: list[HomesShinchikuListing] = []

    # JSON-LD があればベースデータとして使用
    jsonld_items = _parse_jsonld_itemlist(html)

    # HTML パース: 新築ページ固有のブロック
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
                    name=jd.get("name", ""),
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
        name = (name_el.get_text(strip=True) or "").strip() if name_el else ""
        if not name:
            a = block.find("a", href=True)
            if a:
                name = (a.get_text(strip=True) or "").strip()

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
        walk_min = _parse_walk_min(station_line or text)

        # 価格
        price_man, price_max_man = (None, None)
        for line in text.split("\n"):
            line = line.strip()
            if "万円" in line and "タイプ" not in line:
                price_man, price_max_man = _parse_price_range(line)
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
                    area_m2, area_max_m2 = _parse_area_range(parts[1])
                break

        total_units = _parse_total_units(text)
        floor_total = _parse_floor_total(text)

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
        )
    except Exception:
        return None


# ---------- フィルタ ----------

def _is_tokyo_23(address: str) -> bool:
    if not (address and address.strip()):
        return False
    return any(ward in address for ward in TOKYO_23_WARDS)


def _line_ok(station_line: str) -> bool:
    if not ALLOWED_LINE_KEYWORDS:
        return True
    line = (station_line or "").strip()
    if not line:
        return True
    return any(kw in line for kw in ALLOWED_LINE_KEYWORDS)


def _layout_range_ok(layout: str) -> bool:
    if not layout:
        return True
    layout = layout.strip()
    nums = re.findall(r"(\d+)\s*[LDKS]", layout)
    if nums:
        lo = min(int(n) for n in nums)
        hi = max(int(n) for n in nums)
        return lo <= 3 and hi >= 2
    return layout.startswith("2") or layout.startswith("3")


def _load_station_passengers() -> dict[str, int]:
    path = Path(__file__).resolve().parent / "data" / "station_passengers.json"
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def _station_name_from_line(station_line: str) -> str:
    if not (station_line and station_line.strip()):
        return ""
    m = re.search(r"[「『]([^」』]+)[」』]", station_line)
    if m:
        return m.group(1).strip()
    m = re.search(r"([^\s]+駅)", station_line)
    return m.group(1).strip() if m else (station_line.strip()[:30] or "").strip()


def _station_passengers_ok(station_line: str, passengers_map: dict[str, int]) -> bool:
    if STATION_PASSENGERS_MIN <= 0 or not passengers_map:
        return True
    name = _station_name_from_line(station_line or "")
    if not name:
        return True
    passengers = passengers_map.get(name) or passengers_map.get(name.replace("駅", "")) or passengers_map.get(name + "駅")
    if passengers is None:
        return True
    return passengers >= STATION_PASSENGERS_MIN


def apply_conditions(listings: list[HomesShinchikuListing]) -> list[HomesShinchikuListing]:
    """新築用フィルタ。"""
    passengers_map = _load_station_passengers()
    out = []
    for r in listings:
        if not _is_tokyo_23(r.address):
            continue
        if not _line_ok(r.station_line):
            continue
        if not _station_passengers_ok(r.station_line, passengers_map):
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
        if not _layout_range_ok(r.layout):
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
    session = _session()
    limit = max_pages if max_pages and max_pages > 0 else HOMES_SHINCHIKU_MAX_PAGES_SAFETY
    page = 1
    while page <= limit:
        url = LIST_URL_FIRST if page == 1 else LIST_URL_PAGE.format(page=page)
        try:
            html = fetch_list_page(session, url)
        except Exception as e:
            print(f"HOME'S 新築: ページ{page}でエラー: {e}", file=__import__("sys").stderr)
            break
        rows = parse_list_html(html)
        if not rows:
            print(f"HOME'S 新築: ページ{page}で0件パース。一覧のHTML構造が変わった可能性があります。", file=__import__("sys").stderr)
            break
        passed = 0
        for row in rows:
            if apply_filter:
                filtered = apply_conditions([row])
                if filtered:
                    yield filtered[0]
                    passed += 1
            else:
                yield row
                passed += 1
        if apply_filter and rows and passed == 0:
            print(f"HOME'S 新築: ページ{page}で{len(rows)}件パースしたが条件通過0件。", file=__import__("sys").stderr)
        page += 1
