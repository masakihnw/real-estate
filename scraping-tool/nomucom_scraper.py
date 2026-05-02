"""
ノムコム（nomu.com / 野村不動産アーバンネット）中古マンション一覧のスクレイピング。
利用規約: terms-check.md を参照。負荷軽減・私的利用に留めること。
一覧は SearchList ページの div.item_resultsmall カードから取得。
"""

import json
import re
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Iterator, Optional

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
    NOMUCOM_REQUEST_DELAY_SEC,
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


BASE_URL = "https://www.nomu.com"

# 東京23区の区コード（JIS市区町村コード）
TOKYO_23_WARD_CODES = [
    "13101", "13102", "13103", "13104", "13105", "13106", "13107", "13108",
    "13109", "13110", "13111", "13112", "13113", "13114", "13115", "13116",
    "13117", "13118", "13119", "13120", "13121", "13122", "13123",
]

# 全23区を一括取得する SearchList URL
_AREA_PARAMS = "&".join(f"area_id[]={code}" for code in TOKYO_23_WARD_CODES)
LIST_URL_FIRST = f"https://www.nomu.com/mansion/SearchList/?type=area&wide=13&{_AREA_PARAMS}"
LIST_URL_PAGE = LIST_URL_FIRST + "&pager_page={page}"

# 全ページ取得時の安全上限（無限ループ防止）
MAX_PAGES_SAFETY = 100

# 早期打ち切り: 連続 N ページで新規通過0件なら残りをスキップ
EARLY_EXIT_PAGES = 20


@dataclass
class NomucomListing:
    """ノムコム一覧から得た1件分の項目。"""

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
    listing_agent: Optional[str] = "野村不動産アーバンネット"
    is_motodzuke: Optional[bool] = True

    def to_dict(self):
        return asdict(self)


def fetch_list_page(session: requests.Session, url: str) -> str:
    """一覧ページのHTMLを取得。5xx/429/タイムアウト・接続エラー時はリトライする。"""
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(NOMUCOM_REQUEST_DELAY_SEC)
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


def _parse_total_units_nomucom(text: str) -> Optional[int]:
    """「15戸」「120戸」などから総戸数を抽出。ノムコム item_5 用。"""
    if not text:
        return None
    m = re.search(r"(\d+)\s*戸", text)
    return int(m.group(1)) if m else None


def parse_list_html(html: str) -> list[NomucomListing]:
    """ノムコム SearchList ページのHTMLから物件リストをパース。"""
    soup = BeautifulSoup(html, "lxml")
    items: list[NomucomListing] = []

    for card in soup.select("div.item_resultsmall"):
        # --- 物件名・URL ---
        title_div = card.select_one("div.item_title")
        name = ""
        url = ""
        if title_div:
            a = title_div.select_one("a.click_R_link")
            if a:
                name = clean_listing_name((a.get_text(strip=True) or "").strip())
                href = a.get("href", "")
                url = BASE_URL + href if href.startswith("/") else href

        if not url:
            # フォールバック: カード内のマンション詳細リンクを探す
            a = card.find("a", href=re.compile(r"/mansion/id/\d+/"))
            if a:
                href = a.get("href", "")
                url = BASE_URL + href if href.startswith("/") else href
                if not name:
                    name = clean_listing_name((a.get_text(strip=True) or "").strip())

        if not url:
            continue

        # --- 下部テーブル ---
        lower = card.select_one("div.item_resultsmall_lower")
        if not lower:
            continue

        # item_2: 住所・交通
        address = ""
        station_line = ""
        walk_min_val: Optional[int] = None
        td2 = lower.select_one("td.item_2")
        if td2:
            loc_p = td2.select_one("p.item_location")
            if loc_p:
                address = (loc_p.get_text(strip=True) or "").strip()
            acc_p = td2.select_one("p.item_access")
            if acc_p:
                station_line = (acc_p.get_text(separator="\n", strip=True) or "").strip()
                walk_min_val = parse_walk_min(station_line)

        # item_3: 価格
        price_man: Optional[int] = None
        td3 = lower.select_one("td.item_3")
        if td3:
            price_p = td3.select_one("p.item_price")
            if price_p:
                price_text = (price_p.get_text(strip=True) or "").strip()
                price_man = parse_price(price_text)

        # item_4: 面積・間取り・方角 (改行区切り)
        area_m2: Optional[float] = None
        layout = ""
        td4 = lower.select_one("td.item_4")
        if td4:
            # separator なしで面積を取得（m² の上付き2が別行に分離されるのを防ぐ）
            area_m2 = parse_area_m2(td4.get_text() or "")
            td4_text = (td4.get_text(separator="\n", strip=True) or "")
            td4_lines = [line.strip() for line in td4_text.split("\n") if line.strip()]
            for line in td4_lines:
                if not layout and re.search(r"\d+[LDKS]", line):
                    layout = line.strip()

        # item_5: 築年月・階数・総戸数 (改行区切り)
        built_str = ""
        built_year: Optional[int] = None
        floor_position: Optional[int] = None
        floor_total: Optional[int] = None
        total_units: Optional[int] = None
        td5 = lower.select_one("td.item_5")
        if td5:
            td5_text = (td5.get_text(separator="\n", strip=True) or "")
            td5_lines = [line.strip() for line in td5_text.split("\n") if line.strip()]
            for line in td5_lines:
                # 築年月: "1998年9月" のようなパターン
                if built_year is None:
                    by = parse_built_year(line)
                    if by is not None:
                        built_year = by
                        built_str = line.strip()
                # 階数: "8階 / 9階建" のようなパターン
                if floor_position is None:
                    floor_position = parse_floor_position(line)
                if floor_total is None:
                    floor_total = parse_floor_total(line)
                # 総戸数: "15戸" のようなパターン
                if total_units is None:
                    total_units = _parse_total_units_nomucom(line)

        items.append(NomucomListing(
            source="nomucom",
            url=url,
            name=name,
            price_man=price_man,
            address=address,
            station_line=station_line,
            walk_min=walk_min_val,
            area_m2=area_m2,
            layout=layout,
            built_str=built_str,
            built_year=built_year,
            total_units=total_units,
            floor_position=floor_position,
            floor_total=floor_total,
        ))

    if not items:
        title = soup.find("title")
        title_text = title.get_text(strip=True) if title else "(no title)"
        body_snippet = (soup.get_text()[:200] or "").replace("\n", " ")
        logger.warning(
            "nomucom: セレクタが0件 — HTML構造が変わった可能性があります。"
            " title=%r, body_snippet=%r",
            title_text, body_snippet,
        )

    return items


def apply_conditions(listings: list[NomucomListing]) -> list[NomucomListing]:
    """価格・専有・間取り・築年・徒歩・地域（東京23区）・路線・総戸数・駅乗降客数で条件に合わせてフィルタ。"""
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


def scrape_nomucom(max_pages: Optional[int] = 2, apply_filter: bool = True) -> Iterator[NomucomListing]:
    """ノムコム東京23区中古マンション一覧を取得。max_pages=0 のときは結果がなくなるまで全ページ取得。"""
    session = create_session()
    limit = max_pages if max_pages and max_pages > 0 else MAX_PAGES_SAFETY
    page = 1
    total_parsed = 0
    total_passed = 0
    pages_since_last_pass = 0
    while page <= limit:
        url = LIST_URL_FIRST if page == 1 else LIST_URL_PAGE.format(page=page)
        try:
            html = fetch_list_page(session, url)
        except Exception as e:
            logger.error(f"nomucom: ページ{page}でエラー: {e}")
            break
        rows = parse_list_html(html)
        if not rows:
            logger.info(f"nomucom: ページ{page}で0件パース。一覧の終端またはHTML構造変更の可能性。")
            break
        total_parsed += len(rows)
        passed = 0
        for row in rows:
            if apply_filter:
                filtered = apply_conditions([row])
                if filtered:
                    yield filtered[0]
                    passed += 1
                    logger.debug(f"  ✓ {filtered[0].name} ({filtered[0].price_man}万)")
            else:
                yield row
                passed += 1
        total_passed += passed
        if passed > 0:
            pages_since_last_pass = 0
        else:
            pages_since_last_pass += 1
        if pages_since_last_pass >= EARLY_EXIT_PAGES:
            logger.info(f"nomucom: 早期打ち切り（{pages_since_last_pass}ページ連続で通過0件, 累計通過: {total_passed}件）")
            break
        if page % 10 == 0:
            logger.info(f"nomucom: ...{page}ページ処理済 (通過: {total_passed}件)")
        page += 1
    if total_parsed > 0:
        logger.info(f"nomucom: 完了 — {total_parsed}件パース, {total_passed}件通過")


# ──────────────────────────── 詳細ページ ────────────────────────────

_DETAIL_CACHE_PATH = Path(__file__).resolve().parent / "data" / "detail_cache_nomucom.json"
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


def parse_nomucom_detail_html(html: str, url: str = "") -> dict:
    """ノムコム物件詳細ページから追加情報を抽出。"""
    result: dict = {
        "management_fee": None,
        "repair_reserve_fund": None,
        "ownership": None,
        "total_units": None,
        "floor_plan_images": None,
        "suumo_images": None,
    }
    if not html:
        return result

    soup = BeautifulSoup(html, "lxml")

    # th/td テーブルから情報抽出
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

    # 物件IDを抽出 (URL: /mansion/id/FF7C2008/)
    prop_id = ""
    m = re.search(r"/id/([A-Z0-9]+)", url)
    if m:
        prop_id = m.group(1)

    # 画像抽出
    floor_plan_images: list[str] = []
    suumo_images: list[dict] = []
    seen_urls: set[str] = set()

    _EXCLUDE = ("/logo", "/icon", "/btn", "/spacer", "/common/", "/header/",
                "/footer", "/staff/", "/arrow", "/bg_", "/noimages/")

    def _upgrade_nomu_image(src: str) -> str:
        """image.nomu.com の画像URLを高解像度版(_35=1200x900)に変換。"""
        if "image.nomu.com" not in src:
            return src
        # パターン: {ID}_{type}_{size}.jpg — 最後の _XX を _35 に
        return re.sub(r"_(\d{2})\.jpg", r"_35.jpg", src)

    for img in soup.find_all("img"):
        alt = (img.get("alt") or "").strip()
        src = (img.get("data-src") or img.get("src") or "").strip()
        if not src or src.startswith("data:"):
            continue
        if any(x in src for x in _EXCLUDE):
            continue
        if "nomu.com" not in src and not src.startswith("/"):
            continue
        if src.startswith("/"):
            src = BASE_URL + src
        # 自物件の画像のみ (他物件の推薦画像を除外)
        if prop_id and "image.nomu.com" in src and prop_id not in src:
            continue

        src = _upgrade_nomu_image(src)
        if src in seen_urls:
            continue
        seen_urls.add(src)

        if "間取" in alt or "_0701_" in src:
            floor_plan_images.append(src)
        elif "image.nomu.com" in src and alt:
            label = alt
            label = re.sub(r"^【[^】]+】\S+\s*", "", label) or label
            suumo_images.append({"url": src, "label": label})

    if floor_plan_images:
        result["floor_plan_images"] = floor_plan_images
    if suumo_images:
        result["suumo_images"] = suumo_images

    return result


def enrich_nomucom_listings(listings: list[NomucomListing], session=None) -> list[NomucomListing]:
    """フィルタ通過済みリストの各物件の詳細ページを取得し、追加情報を注入する。"""
    if not listings:
        return listings

    if session is None:
        session = create_session()

    cache = _load_detail_cache()
    enriched_count = 0

    for listing in listings:
        cached = cache.get(listing.url)
        if cached and not cached.get("suumo_images"):
            cached = None
        if cached:
            detail = cached
        else:
            time.sleep(NOMUCOM_REQUEST_DELAY_SEC)
            html = _fetch_detail_page(session, listing.url)
            detail = parse_nomucom_detail_html(html, listing.url)
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
        if detail.get("floor_plan_images"):
            listing.floor_plan_images = detail["floor_plan_images"]
        if detail.get("suumo_images"):
            listing.suumo_images = detail["suumo_images"]

        enriched_count += 1
        if enriched_count % 10 == 0:
            logger.info(f"nomucom detail: {enriched_count}/{len(listings)}件取得済")

    _save_detail_cache(cache)
    logger.info(f"nomucom detail: 完了 — {enriched_count}件エンリッチ")
    return listings
