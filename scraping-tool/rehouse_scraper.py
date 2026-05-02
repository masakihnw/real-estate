"""
三井のリハウス（rehouse.co.jp）中古マンション一覧のスクレイピング。
利用規約: terms-check.md を参照。負荷軽減・私的利用に留めること。
検索ページ (/buy/mansion/prefecture/13/city/{ward}/) を区ごとに取得。
"""

import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Iterator, Optional
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

from config import (
    PRICE_MIN_MAN,
    PRICE_MAX_MAN,
    AREA_MIN_M2,
    AREA_MAX_M2,
    BUILT_YEAR_MIN,
    WALK_MIN_MAX,
    TOTAL_UNITS_MIN,
    STATION_PASSENGERS_MIN,
    ALLOWED_LINE_KEYWORDS,
    REHOUSE_REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
    REQUEST_RETRIES,
)
from parse_utils import (
    parse_price,
    parse_area_m2,
    parse_walk_min,
    parse_built_year,
    parse_floor_position,
    parse_floor_total,
    parse_monthly_yen,
    parse_total_units_strict,
    layout_ok,
)
from report_utils import clean_listing_name
from scraper_common import (
    create_session,
    load_station_passengers,
    station_passengers_ok,
    line_ok,
    is_tokyo_23_by_address,
)

from logger import get_logger
logger = get_logger(__name__)


BASE_URL = "https://www.rehouse.co.jp"

# 区ごとの検索URL (サーバーサイドで価格・面積フィルタ可能)
_WARD_URL_TEMPLATE = (
    "https://www.rehouse.co.jp/buy/mansion/prefecture/13/city/{ward_code}/"
    "?priceLowerLimit={price_min}&exclusiveAreaLowerLimit={area_min}"
)
_WARD_URL_PAGE_TEMPLATE = (
    "https://www.rehouse.co.jp/buy/mansion/prefecture/13/city/{ward_code}/"
    "?priceLowerLimit={price_min}&exclusiveAreaLowerLimit={area_min}&page={page}"
)

_WARD_CODES = (
    "13101", "13102", "13103", "13104", "13105", "13106", "13107", "13108",
    "13109", "13110", "13111", "13112", "13113", "13114", "13115", "13116",
    "13117", "13118", "13119", "13120", "13121", "13122", "13123",
)

MAX_PAGES_PER_WARD = 30
PARALLEL_WARD_WORKERS = 3
EARLY_EXIT_PAGES = 5


@dataclass
class RehouseListing:
    """三井のリハウス 一覧から得た1件分の項目。"""

    source: str
    url: str
    name: str
    price_man: Optional[int]
    address: str
    station_line: str
    walk_min: Optional[int]
    area_m2: Optional[float]
    layout: str
    built_str: str
    built_year: Optional[int]
    total_units: Optional[int] = None
    floor_position: Optional[int] = None
    floor_total: Optional[int] = None
    management_fee: Optional[int] = None
    repair_reserve_fund: Optional[int] = None
    ownership: Optional[str] = None
    suumo_images: Optional[list] = None
    floor_plan_images: Optional[list] = None
    listing_agent: Optional[str] = "三井のリハウス"
    is_motodzuke: Optional[bool] = True

    def to_dict(self):
        return asdict(self)


def fetch_list_page(session: requests.Session, url: str) -> str:
    """一覧ページのHTMLを取得。5xx/429/タイムアウト・接続エラー時はリトライする。"""
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(REHOUSE_REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                logger.warning(f"  429 Rate Limited, waiting {retry_after}s (attempt {attempt + 1})")
                time.sleep(retry_after)
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
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
    raise RuntimeError(f"全リトライが失敗しました: {url}")


def parse_list_html(html: str, base_url: str = BASE_URL) -> list[RehouseListing]:
    """三井のリハウス 検索結果HTMLから物件リストをパース。

    各物件は div.property-index-card 内に:
      - h2.property-title (物件名)
      - span.price (価格: "69,800" — 万円は外)
      - div.content > p.paragraph-body.gray ×2:
        [0] "港区浜松町１丁目 / 山手線 浜松町駅 徒歩5分"
        [1] "3LDK / 87.56㎡ / 2019年02月築 / 36階"
      - a[href*="/buy/mansion/bkdetail/"] (詳細URL)
    """
    soup = BeautifulSoup(html, "lxml")
    cards = soup.select("div.property-index-card")
    items: list[RehouseListing] = []

    for card in cards:
        # URL
        link = card.select_one('a[href*="/buy/mansion/bkdetail/"]')
        if not link:
            continue
        href = link.get("href", "")
        url = urljoin(base_url, href) if href else ""
        if not url:
            continue

        # 物件名
        title_el = card.select_one("h2.property-title")
        name = clean_listing_name(title_el.get_text(strip=True) or "") if title_el else ""

        # 価格 (span.price は "69,800" のように数値のみ)
        price_man: Optional[int] = None
        price_span = card.select_one("span.price")
        if price_span:
            price_text = (price_span.get_text(strip=True) or "").replace(",", "")
            price_man = parse_price(price_text + "万円") if price_text else None

        # コンテンツ段落:
        # [0] "住所 / 路線 駅名 徒歩N分"
        # [1] "間取り / 面積㎡ / 築年月 / 階"
        content_div = card.select_one("div.content")
        paragraphs = content_div.select("p.paragraph-body") if content_div else []

        address = ""
        station_line = ""
        layout = ""
        area_m2: Optional[float] = None
        built_str = ""
        built_year: Optional[int] = None
        walk_min: Optional[int] = None
        floor_position: Optional[int] = None
        floor_total: Optional[int] = None

        if len(paragraphs) >= 1:
            line1 = (paragraphs[0].get_text(strip=True) or "").strip()
            # "港区浜松町１丁目 / 山手線 浜松町駅 徒歩5分"
            parts = line1.split("/")
            if len(parts) >= 2:
                address = parts[0].strip()
                station_line = "/".join(parts[1:]).strip()
            else:
                address = line1
            walk_min = parse_walk_min(line1)

        if len(paragraphs) >= 2:
            line2 = (paragraphs[1].get_text(strip=True) or "").strip()
            # "3LDK / 87.56㎡ / 2019年02月築 / 36階"
            parts = line2.split("/")
            for part in parts:
                p = part.strip()
                if re.match(r"\d+[LDKS]+", p):
                    layout = p
                elif "㎡" in p or "m2" in p.lower():
                    area_m2 = parse_area_m2(p)
                elif "築" in p or re.search(r"\d{4}年", p):
                    built_str = p
                    built_year = parse_built_year(p)
                elif "階" in p:
                    floor_position = parse_floor_position(p)

        items.append(RehouseListing(
            source="rehouse",
            url=url,
            name=name,
            price_man=price_man,
            address=address,
            station_line=station_line,
            walk_min=walk_min,
            area_m2=area_m2,
            layout=layout,
            built_str=built_str,
            built_year=built_year,
            total_units=None,
            floor_position=floor_position,
            floor_total=floor_total,
        ))

    if not items and cards:
        title = soup.find("title")
        title_text = title.get_text(strip=True) if title else "(no title)"
        logger.warning(
            "rehouse: div.property-index-card は存在するがパース0件 — HTML構造変更の可能性。 title=%r",
            title_text,
        )
    elif not items:
        title = soup.find("title")
        title_text = title.get_text(strip=True) if title else "(no title)"
        logger.debug("rehouse: ページに物件カードなし。 title=%r", title_text)

    return items


def apply_conditions(listings: list[RehouseListing]) -> list[RehouseListing]:
    """価格・専有・間取り・築年・徒歩・地域（東京23区）・路線・総戸数・駅乗降客数で条件フィルタ。"""
    passengers_map = load_station_passengers()
    out = []
    for r in listings:
        if not is_tokyo_23_by_address(r.address):
            continue
        if not line_ok(r.station_line, empty_passes=True):
            continue
        if not station_passengers_ok(r.station_line, passengers_map):
            continue
        if r.price_man is not None and (r.price_man < PRICE_MIN_MAN or r.price_man > PRICE_MAX_MAN):
            continue
        if r.area_m2 is not None and (r.area_m2 < AREA_MIN_M2 or (AREA_MAX_M2 is not None and r.area_m2 > AREA_MAX_M2)):
            continue
        if not layout_ok(r.layout):
            continue
        if r.built_year is not None and r.built_year < BUILT_YEAR_MIN:
            continue
        if r.walk_min is not None and r.walk_min > WALK_MIN_MAX:
            continue
        if r.total_units is not None and r.total_units < TOTAL_UNITS_MIN:
            continue
        out.append(r)
    return out


def _scrape_ward(ward_code: str, apply_filter: bool,
                  seen_urls: set, url_lock: threading.Lock) -> list[RehouseListing]:
    """1区分のスクレイピング。全ページ巡回して条件合致物件を返す。"""
    session = create_session()
    results: list[RehouseListing] = []
    price_min = PRICE_MIN_MAN if PRICE_MIN_MAN else 0
    area_min = int(AREA_MIN_M2) if AREA_MIN_M2 else 0
    pages_no_pass = 0

    for page in range(1, MAX_PAGES_PER_WARD + 1):
        if page == 1:
            url = _WARD_URL_TEMPLATE.format(
                ward_code=ward_code, price_min=price_min, area_min=area_min)
        else:
            url = _WARD_URL_PAGE_TEMPLATE.format(
                ward_code=ward_code, price_min=price_min, area_min=area_min, page=page)

        try:
            html = fetch_list_page(session, url)
        except Exception as e:
            logger.warning(f"rehouse: ward={ward_code} page={page} エラー: {e}")
            break

        rows = parse_list_html(html)
        if not rows:
            break

        passed = 0
        for row in rows:
            with url_lock:
                if row.url in seen_urls:
                    continue
                seen_urls.add(row.url)
            if apply_filter:
                filtered = apply_conditions([row])
                if filtered:
                    results.append(filtered[0])
                    passed += 1
            else:
                results.append(row)
                passed += 1

        if passed > 0:
            pages_no_pass = 0
        else:
            pages_no_pass += 1
        if pages_no_pass >= EARLY_EXIT_PAGES:
            break

    return results


def scrape_rehouse(max_pages: Optional[int] = None, apply_filter: bool = True) -> Iterator[RehouseListing]:
    """三井のリハウス 東京23区を区ごとに並列取得。max_pages は後方互換のため残置。"""
    seen_urls: set = set()
    url_lock = threading.Lock()
    all_results: list[RehouseListing] = []

    def _worker(ward_code: str) -> list[RehouseListing]:
        return _scrape_ward(ward_code, apply_filter, seen_urls, url_lock)

    with ThreadPoolExecutor(max_workers=PARALLEL_WARD_WORKERS) as executor:
        futures = {executor.submit(_worker, wc): wc for wc in _WARD_CODES}
        for future in as_completed(futures):
            ward_code = futures[future]
            try:
                ward_results = future.result()
                all_results.extend(ward_results)
                if ward_results:
                    logger.info(f"rehouse: ward={ward_code} → {len(ward_results)}件通過")
            except Exception as e:
                logger.error(f"rehouse: ward={ward_code} 失敗: {e}")

    logger.info(f"rehouse: 完了 — 全{len(all_results)}件通過 (23区)")
    yield from all_results


# ──────────────────────────── 詳細ページ ────────────────────────────

_DETAIL_CACHE_PATH = Path(__file__).resolve().parent / "data" / "detail_cache_rehouse.json"
_CACHE_EXPIRY_DAYS = 90


def _load_detail_cache() -> dict:
    if not _DETAIL_CACHE_PATH.exists():
        return {}
    try:
        with open(_DETAIL_CACHE_PATH, "r", encoding="utf-8") as f:
            cache = json.load(f)
        cutoff = (datetime.now(timezone.utc) - timedelta(days=_CACHE_EXPIRY_DAYS)).isoformat()
        return {k: v for k, v in cache.items() if v.get("cached_at", "") >= cutoff}
    except (json.JSONDecodeError, OSError):
        return {}


def _save_detail_cache(cache: dict) -> None:
    _DETAIL_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(_DETAIL_CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=1)


def _fetch_detail_page(session: requests.Session, url: str) -> str:
    for attempt in range(REQUEST_RETRIES):
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            if r.status_code == 429:
                time.sleep(int(r.headers.get("Retry-After", 30)))
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
        except (requests.exceptions.HTTPError, requests.exceptions.Timeout,
                requests.exceptions.ConnectionError):
            if attempt < REQUEST_RETRIES - 1:
                time.sleep(3)
    return ""


def parse_rehouse_detail_html(html: str, url: str = "") -> dict:
    """リハウス物件詳細ページから追加情報を抽出。"""
    result: dict = {
        "management_fee": None,
        "repair_reserve_fund": None,
        "ownership": None,
        "total_units": None,
        "floor_position": None,
        "floor_total": None,
        "floor_plan_images": None,
        "suumo_images": None,
    }
    if not html:
        return result

    soup = BeautifulSoup(html, "lxml")

    # テーブル（th/td ペア）から情報抽出
    for tr in soup.find_all("tr"):
        cells = tr.find_all(["th", "td"], recursive=False)
        for i, cell in enumerate(cells):
            if cell.name != "th" or i + 1 >= len(cells):
                continue
            th = (cell.get_text(strip=True) or "").strip()
            td = (cells[i + 1].get_text(strip=True) or "").strip()

            if "管理費" in th and "修繕" not in th:
                val = parse_monthly_yen(td)
                if val and val > 0:
                    result["management_fee"] = val
            elif "修繕積立金" in th:
                val = parse_monthly_yen(td)
                if val and val > 0:
                    result["repair_reserve_fund"] = val
            elif "権利" in th or "所有権" in th:
                if td and td != "-":
                    result["ownership"] = td
            elif "総戸数" in th:
                m = re.search(r"(\d+)\s*戸", td)
                if m:
                    result["total_units"] = int(m.group(1))
            elif "階数" in th or "階建" in th or "所在階" in th:
                result["floor_position"] = parse_floor_position(td)
                m = re.search(r"地上\s*(\d+)\s*階", td)
                if m:
                    result["floor_total"] = int(m.group(1))
                else:
                    result["floor_total"] = parse_floor_total(td)

    # dl/dt/dd パターンも試行
    for dt in soup.find_all("dt"):
        dt_text = (dt.get_text(strip=True) or "").strip()
        dd = dt.find_next_sibling("dd")
        if not dd:
            continue
        dd_text = (dd.get_text(strip=True) or "").strip()

        if "管理費" in dt_text and "修繕" not in dt_text and not result["management_fee"]:
            val = parse_monthly_yen(dd_text)
            if val and val > 0:
                result["management_fee"] = val
        elif "修繕積立金" in dt_text and not result["repair_reserve_fund"]:
            val = parse_monthly_yen(dd_text)
            if val and val > 0:
                result["repair_reserve_fund"] = val
        elif ("権利" in dt_text or "所有権" in dt_text) and not result["ownership"]:
            if dd_text and dd_text != "-":
                result["ownership"] = dd_text
        elif "総戸数" in dt_text and not result["total_units"]:
            m = re.search(r"(\d+)\s*戸", dd_text)
            if m:
                result["total_units"] = int(m.group(1))
        elif ("階数" in dt_text or "階建" in dt_text or "所在階" in dt_text) and not result.get("floor_position"):
            result["floor_position"] = parse_floor_position(dd_text)
            m = re.search(r"地上\s*(\d+)\s*階", dd_text)
            if m:
                result["floor_total"] = int(m.group(1))
            else:
                result["floor_total"] = parse_floor_total(dd_text)

    # 画像抽出
    floor_plan_images: list[str] = []
    suumo_images: list[dict] = []
    seen_urls: set[str] = set()

    for img in soup.find_all("img"):
        alt = (img.get("alt") or "").strip()
        src = (img.get("data-src") or img.get("src") or "").strip()
        if not src or src.startswith("data:"):
            continue
        if any(x in src for x in ("/logo", "/icon", "/btn", "/spacer", "/common/")):
            continue
        if src in seen_urls:
            continue
        if not any(x in src for x in ("rehouse", "cdn", "miraie")) and not src.startswith("/"):
            continue
        if src.startswith("/"):
            src = BASE_URL + src

        seen_urls.add(src)
        if "間取" in alt:
            floor_plan_images.append(src)
        elif alt and alt not in ("", "写真", "画像"):
            suumo_images.append({"url": src, "label": alt})
        elif "/photo/" in src or "/image/" in src or "miraie" in src:
            suumo_images.append({"url": src, "label": alt or "外観"})

    if floor_plan_images:
        result["floor_plan_images"] = floor_plan_images
    if suumo_images:
        result["suumo_images"] = suumo_images

    return result


def enrich_rehouse_listings(listings: list[RehouseListing], session=None) -> list[RehouseListing]:
    """フィルタ通過済みリストの各物件の詳細ページを取得し、追加情報を注入する。"""
    if not listings:
        return listings

    if session is None:
        session = create_session()

    cache = _load_detail_cache()
    enriched_count = 0

    _img_cache_cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()

    for listing in listings:
        cached = cache.get(listing.url)
        if cached and not cached.get("floor_plan_images") and not cached.get("suumo_images"):
            if cached.get("cached_at", "") < _img_cache_cutoff:
                cached = None
        if cached:
            detail = cached
        else:
            time.sleep(REHOUSE_REQUEST_DELAY_SEC)
            html = _fetch_detail_page(session, listing.url)
            detail = parse_rehouse_detail_html(html, listing.url)
            detail["cached_at"] = datetime.now(timezone.utc).isoformat()
            cache[listing.url] = detail

        if detail.get("management_fee") and not listing.management_fee:
            listing.management_fee = detail["management_fee"]
        if detail.get("repair_reserve_fund") and not listing.repair_reserve_fund:
            listing.repair_reserve_fund = detail["repair_reserve_fund"]
        if detail.get("ownership") and not listing.ownership:
            listing.ownership = detail["ownership"]
        if detail.get("total_units") and not listing.total_units:
            listing.total_units = detail["total_units"]
        if listing.floor_position is None and detail.get("floor_position") is not None:
            listing.floor_position = detail["floor_position"]
        if listing.floor_total is None and detail.get("floor_total") is not None:
            listing.floor_total = detail["floor_total"]
        if detail.get("floor_plan_images"):
            listing.floor_plan_images = detail["floor_plan_images"]
        if detail.get("suumo_images"):
            listing.suumo_images = detail["suumo_images"]

        enriched_count += 1
        if enriched_count % 10 == 0:
            logger.info(f"rehouse detail: {enriched_count}/{len(listings)}件取得済")

    _save_detail_cache(cache)
    logger.info(f"rehouse detail: 完了 — {enriched_count}件エンリッチ")
    return listings
