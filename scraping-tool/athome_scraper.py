"""
アットホーム（athome.co.jp）中古マンション一覧のスクレイピング。
利用規約を遵守し、負荷軽減・私的利用に留めること。
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
    ATHOME_REQUEST_DELAY_SEC,
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

BASE_URL = "https://www.athome.co.jp"

# 東京都・中古マンション一覧
LIST_URL_FIRST = "https://www.athome.co.jp/mansion/chuko/tokyo/list/"
LIST_URL_PAGE = "https://www.athome.co.jp/mansion/chuko/tokyo/list/page{page}/"

# 安全上限（無限ループ防止）
MAX_PAGES_SAFETY = 100

# 早期打ち切り: 連続 N ページで新規通過0件なら残りをスキップ
EARLY_EXIT_PAGES = 20

# detail table のラベルキー（分割用）
_DETAIL_LABELS = ("間取り", "築年月", "階建", "構造", "専有面積", "所在地", "交通", "総戸数", "管理費", "修繕積立金")


@dataclass
class AthomeListing:
    """アットホーム一覧から得た1件分の項目。"""

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
    listing_agent: Optional[str] = None

    def to_dict(self):
        return asdict(self)


def fetch_list_page(session: requests.Session, page: int) -> str:
    """一覧ページのHTMLを取得。429/5xx時はリトライする。"""
    url = LIST_URL_FIRST if page == 1 else LIST_URL_PAGE.format(page=page)
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(ATHOME_REQUEST_DELAY_SEC)
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
    raise RuntimeError(f"全リトライが失敗しました: page={page}")


def _parse_detail_blocks(detail_div) -> dict[str, str]:
    """property-detail-table 内のブロックからラベル→値の辞書を作成。"""
    result: dict[str, str] = {}
    if detail_div is None:
        return result
    blocks = detail_div.select("div.property-detail-table__block")
    for block in blocks:
        text = (block.get_text(strip=True) or "").strip()
        if not text:
            continue
        # ラベルと値を分離: 既知のラベルでテキストを分割
        for label in _DETAIL_LABELS:
            if text.startswith(label):
                value = text[len(label):].strip()
                # span.fwb 内のテキストがあればそちらを優先
                fwb = block.select_one("span.fwb")
                if fwb:
                    value = (fwb.get_text(strip=True) or "").strip()
                result[label] = value
                break
    return result


def _parse_total_units_athome(text: str) -> Optional[int]:
    """「総戸数30戸」「30戸」などから総戸数を抽出。"""
    if not text:
        return None
    m = re.search(r"(?:総戸数\s*)?(\d+)\s*戸", text)
    return int(m.group(1)) if m else None


def _parse_floor_info(text: str) -> tuple[Optional[int], Optional[int]]:
    """「3階建 / 3階」から (floor_total, floor_position) を返す。"""
    floor_total = parse_floor_total(text)
    floor_position = parse_floor_position(text)
    return floor_total, floor_position


def parse_list_html(html: str) -> list[AthomeListing]:
    """アットホーム一覧HTMLから物件リストをパース。"""
    soup = BeautifulSoup(html, "lxml")
    items: list[AthomeListing] = []

    # web component カード内の card-box を探す
    cards = soup.select("div.card-box")
    if not cards:
        # フォールバック: web component タグから探す
        cards = soup.select("athome-csite-pc-part-bukken-card-ryutsu-sell-living")

    for card in cards:
        # 詳細リンクの取得
        detail_link = card.select_one('a[href*="/mansion/"]')
        if not detail_link:
            continue
        href = detail_link.get("href", "")
        if not href or "/mansion/" not in href:
            continue
        # ID抽出してURLを正規化
        m_id = re.search(r"/mansion/(\d+)/", href)
        if m_id:
            url = f"{BASE_URL}/mansion/{m_id.group(1)}/"
        else:
            url = href if href.startswith("http") else BASE_URL + href
            # クエリパラメータを除去
            url = url.split("?")[0]

        # 物件名: card-box-open 内の title-wrap__title-text を優先
        # (card-box-close 内のものは価格がくっついている)
        open_section = card.select_one("div.card-box-open")
        name_el = open_section.select_one("div.title-wrap__title-text") if open_section else None
        if not name_el:
            name_el = card.select_one("div.title-wrap__title-text")
        name = clean_listing_name((name_el.get_text(strip=True) or "").strip()) if name_el else ""

        # 価格
        price_el = card.select_one("div.property-price")
        price_man = parse_price((price_el.get_text(strip=True) or "").strip()) if price_el else None

        # detail table から各項目を取得
        detail_table = card.select_one("div.property-detail-table")
        detail = _parse_detail_blocks(detail_table)

        layout = detail.get("間取り", "")
        built_str = detail.get("築年月", "")
        built_year = parse_built_year(built_str)
        floor_text = detail.get("階建", "")
        floor_total, floor_position = _parse_floor_info(floor_text)
        area_str = detail.get("専有面積", "")
        area_m2 = parse_area_m2(area_str)
        address = detail.get("所在地", "")
        station_line = detail.get("交通", "")
        walk_min = parse_walk_min(station_line)

        # 総戸数
        total_units_str = detail.get("総戸数", "")
        total_units = _parse_total_units_athome(total_units_str)
        if total_units is None:
            total_units = parse_total_units_strict(card.get_text() or "")

        # 管理費・修繕積立金
        mgmt_str = detail.get("管理費", "")
        repair_str = detail.get("修繕積立金", "")
        management_fee = parse_monthly_yen(mgmt_str) if mgmt_str else None
        repair_reserve_fund = parse_monthly_yen(repair_str) if repair_str else None

        # 仲介業者
        agent_el = card.select_one("div.estate-text-area__title-wrap")
        listing_agent = (agent_el.get_text(strip=True) or "").strip() if agent_el else None

        items.append(AthomeListing(
            source="athome",
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
            total_units=total_units,
            floor_position=floor_position,
            floor_total=floor_total,
            management_fee=management_fee,
            repair_reserve_fund=repair_reserve_fund,
            listing_agent=listing_agent,
        ))

    if not items and html.strip():
        title = soup.find("title")
        title_text = title.get_text(strip=True) if title else "(no title)"
        body_snippet = (soup.get_text()[:200] or "").replace("\n", " ")
        logger.warning(
            "athome: セレクタが0件 — HTML構造が変わった可能性があります。"
            " title=%r, body_snippet=%r",
            title_text, body_snippet,
        )

    return items


def apply_conditions(listings: list[AthomeListing]) -> list[AthomeListing]:
    """価格・専有・間取り・築年・徒歩・地域（東京23区）・路線・総戸数・駅乗降客数でフィルタ。"""
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


def scrape_athome(max_pages: Optional[int] = 2, apply_filter: bool = True) -> Iterator[AthomeListing]:
    """アットホーム東京中古マンション一覧を取得。max_pages=0 で全ページ取得。"""
    session = create_session()
    limit = max_pages if max_pages and max_pages > 0 else MAX_PAGES_SAFETY
    page = 1
    total_parsed = 0
    total_passed = 0
    pages_since_last_pass = 0

    while page <= limit:
        try:
            html = fetch_list_page(session, page)
        except Exception as e:
            logger.error(f"athome: ページ{page}でエラー: {e}")
            break

        rows = parse_list_html(html)
        if not rows:
            logger.info(f"athome: ページ{page}で0件パース。一覧終了または HTML構造変更の可能性。")
            break

        total_parsed += len(rows)
        passed = 0
        for row in rows:
            if apply_filter:
                filtered = apply_conditions([row])
                if filtered:
                    yield filtered[0]
                    passed += 1
                    logger.debug(f"  pass: {filtered[0].name} ({filtered[0].price_man}万)")
            else:
                yield row
                passed += 1

        total_passed += passed

        # 早期打ち切り判定
        if passed > 0:
            pages_since_last_pass = 0
        else:
            pages_since_last_pass += 1
        if pages_since_last_pass >= EARLY_EXIT_PAGES:
            logger.info(f"athome: 早期打ち切り（{pages_since_last_pass}ページ連続で通過0件, 累計通過: {total_passed}件）")
            break

        # 進捗ログ: 10ページごと
        if page % 10 == 0:
            logger.info(f"athome: ...{page}ページ処理済 (通過: {total_passed}件)")

        page += 1

    if total_parsed > 0:
        logger.info(f"athome: 完了 — {total_parsed}件パース, {total_passed}件通過")
