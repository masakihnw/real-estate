"""
ノムコム（nomu.com / 野村不動産アーバンネット）中古マンション一覧のスクレイピング。
利用規約: terms-check.md を参照。負荷軽減・私的利用に留めること。
一覧は SearchList ページの div.item_resultsmall カードから取得。
"""

import re
import time
from dataclasses import dataclass, asdict
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
        if not line_ok(r.station_line, empty_passes=False):
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
