"""
三井のリハウス（rehouse.co.jp）中古マンション一覧のスクレイピング。
利用規約: terms-check.md を参照。負荷軽減・私的利用に留めること。
一覧は Nuxt.js SSR で HTML が直接取得可能。
"""

import re
import time
from dataclasses import dataclass, asdict
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

# 東京都・中古マンション一覧
LIST_URL_FIRST = "https://www.rehouse.co.jp/mansion/tokyo/"
LIST_URL_PAGE = "https://www.rehouse.co.jp/mansion/tokyo/?page={page}"

# 全ページ取得時の安全上限（無限ループ防止）
MAX_PAGES_SAFETY = 100

# 早期打ち切り: 連続 N ページで新規通過0件なら残りをスキップ
EARLY_EXIT_PAGES = 20


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
    """三井のリハウス 一覧HTMLから物件リストをパース。

    各物件は div.property-card 内に:
      - a.property-card__link (href: /buy/mansion/bkdetail/{ID}/)
      - h3.property-title (物件名)
      - p.price-text / span.price (価格)
      - div.content > p.paragraph-body.gray (住所, 路線駅, 間取り/面積, 築年月)
    """
    soup = BeautifulSoup(html, "lxml")
    cards = soup.select("div.property-card")
    items: list[RehouseListing] = []

    for card in cards:
        # URL
        link = card.select_one("a.property-card__link")
        if not link:
            continue
        href = link.get("href", "")
        url = urljoin(base_url, href) if href else ""
        if not url:
            continue

        # 物件名
        title_el = card.select_one("h3.property-title")
        name = clean_listing_name((title_el.get_text(strip=True) or "")) if title_el else ""

        # 価格
        price_man: Optional[int] = None
        price_span = card.select_one("span.price")
        if price_span:
            price_text = (price_span.get_text(strip=True) or "").replace(",", "")
            # span.price には数値のみ入ることがあるため万円を補完
            price_man = parse_price(price_text + "万円") if price_text else None
        if price_man is None:
            price_el = card.select_one("p.price-text")
            if price_el:
                price_man = parse_price(price_el.get_text(strip=True) or "")

        # コンテンツ段落: 住所, 路線駅, 間取り/面積, 築年月
        content_div = card.select_one("div.content")
        paragraphs = content_div.select("p.paragraph-body.gray") if content_div else []

        address = ""
        station_line = ""
        layout = ""
        area_m2: Optional[float] = None
        built_str = ""
        built_year: Optional[int] = None
        walk_min: Optional[int] = None
        floor_position: Optional[int] = None
        floor_total: Optional[int] = None

        # 段落は順に: 住所, 路線駅, 間取り/面積, 築年月
        if len(paragraphs) >= 1:
            address = (paragraphs[0].get_text(strip=True) or "").strip()
        if len(paragraphs) >= 2:
            station_text = (paragraphs[1].get_text(strip=True) or "").strip()
            station_line = station_text
            walk_min = parse_walk_min(station_text)
        if len(paragraphs) >= 3:
            layout_area_text = (paragraphs[2].get_text(strip=True) or "").strip()
            # "3LDK / 80.08㎡" のような形式を分割
            parts = layout_area_text.split("/")
            if len(parts) >= 2:
                layout = parts[0].strip()
                area_m2 = parse_area_m2(parts[1].strip())
            elif len(parts) == 1:
                # "/"なしの場合: 間取りと面積が混在
                layout_area = parts[0].strip()
                # 間取り部分を抽出
                m = re.match(r"([0-9]+[LDKS]+)", layout_area)
                if m:
                    layout = m.group(1)
                area_m2 = parse_area_m2(layout_area)
        if len(paragraphs) >= 4:
            built_text = (paragraphs[3].get_text(strip=True) or "").strip()
            built_str = built_text
            built_year = parse_built_year(built_text)

        # カード全体テキストからフロア情報をフォールバック取得
        card_text = card.get_text() or ""
        floor_position = parse_floor_position(card_text)
        floor_total = parse_floor_total(card_text)

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
            total_units=None,  # 一覧ページには総戸数なし
            floor_position=floor_position,
            floor_total=floor_total,
        ))

    if not items and cards:
        # カードはあるのにパースできなかった: HTML 構造の変更を疑う
        title = soup.find("title")
        title_text = title.get_text(strip=True) if title else "(no title)"
        logger.warning(
            "rehouse: div.property-card は存在するがパース0件 — HTML構造が変わった可能性があります。"
            " title=%r",
            title_text,
        )
    elif not items:
        title = soup.find("title")
        title_text = title.get_text(strip=True) if title else "(no title)"
        body_snippet = (soup.get_text()[:200] or "").replace("\n", " ")
        logger.warning(
            "rehouse: セレクタが0件 — HTML構造が変わった可能性があります。"
            " title=%r, body_snippet=%r",
            title_text, body_snippet,
        )

    return items


def apply_conditions(listings: list[RehouseListing]) -> list[RehouseListing]:
    """価格・専有・間取り・築年・徒歩・地域（東京23区）・路線・総戸数・駅乗降客数で条件フィルタ。"""
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


def scrape_rehouse(max_pages: Optional[int] = 2, apply_filter: bool = True) -> Iterator[RehouseListing]:
    """三井のリハウス 東京中古マンション一覧を取得。max_pages=0 のときは結果がなくなるまで全ページ取得。"""
    session = create_session()
    limit = max_pages if max_pages and max_pages > 0 else MAX_PAGES_SAFETY
    page = 1
    total_parsed = 0
    total_passed = 0
    pages_since_last_pass = 0  # 最後の通過からの連続ページ数（早期打ち切り用）
    while page <= limit:
        url = LIST_URL_FIRST if page == 1 else LIST_URL_PAGE.format(page=page)
        try:
            html = fetch_list_page(session, url)
        except Exception as e:
            logger.error(f"rehouse: ページ{page}でエラー: {e}")
            break
        rows = parse_list_html(html)
        if not rows:
            logger.info(f"rehouse: ページ{page}で0件パース。一覧終了または構造変更の可能性。")
            break
        total_parsed += len(rows)
        passed = 0
        for row in rows:
            if apply_filter:
                filtered = apply_conditions([row])
                if filtered:
                    yield filtered[0]
                    passed += 1
                    logger.debug(f"  -> {filtered[0].name} ({filtered[0].price_man}万)")
            else:
                yield row
                passed += 1
        total_passed += passed
        # 早期打ち切り判定: 連続 N ページで新規通過0件なら中断
        if passed > 0:
            pages_since_last_pass = 0
        else:
            pages_since_last_pass += 1
        if pages_since_last_pass >= EARLY_EXIT_PAGES:
            logger.info(f"rehouse: 早期打ち切り（{pages_since_last_pass}ページ連続で通過0件, 累計通過: {total_passed}件）")
            break
        # 進捗: 10ページごとにサマリー
        if page % 10 == 0:
            logger.info(f"rehouse: ...{page}ページ処理済 (通過: {total_passed}件)")
        page += 1
    if total_parsed > 0:
        logger.info(f"rehouse: 完了 — {total_parsed}件パース, {total_passed}件通過")
