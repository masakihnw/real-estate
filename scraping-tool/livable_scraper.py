"""
東急リバブル（livable.co.jp）中古マンション一覧のスクレイピング。
利用規約を遵守し、負荷軽減・私的利用に留めること。
一覧は CSS Modules（ハッシュ付きクラス名）を使用しているため、
ベースクラス名の部分一致で要素を特定する。
区ごとに並列取得し、各区をページネーションする。
"""

import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from typing import Iterator, Optional
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup, Tag

from config import (
    PRICE_MIN_MAN,
    PRICE_MAX_MAN,
    AREA_MIN_M2,
    AREA_MAX_M2,
    BUILT_YEAR_MIN,
    WALK_MIN_MAX,
    TOTAL_UNITS_MIN,
    LIVABLE_REQUEST_DELAY_SEC,
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


BASE_URL = "https://www.livable.co.jp"

# 東京23区の区コード（JIS市区町村コード）— nomucom と同一
TOKYO_23_WARD_CODES: dict[str, str] = {
    "13101": "千代田区", "13102": "中央区", "13103": "港区",
    "13104": "新宿区", "13105": "文京区", "13106": "台東区",
    "13107": "墨田区", "13108": "江東区", "13109": "品川区",
    "13110": "目黒区", "13111": "大田区", "13112": "世田谷区",
    "13113": "渋谷区", "13114": "中野区", "13115": "杉並区",
    "13116": "豊島区", "13117": "北区", "13118": "荒川区",
    "13119": "板橋区", "13120": "練馬区", "13121": "足立区",
    "13122": "葛飾区", "13123": "江戸川区",
}

# 区ごとの一覧URL
WARD_LIST_URL = "https://www.livable.co.jp/kounyu/chuko-mansion/tokyo/a{ward_code}/"
WARD_LIST_URL_PAGE = "https://www.livable.co.jp/kounyu/chuko-mansion/tokyo/a{ward_code}/?page={page}"

# 全ページ取得時の安全上限（無限ループ防止）
MAX_PAGES_SAFETY = 100

# 早期打ち切り: 連続 N ページで新規通過0件なら残りをスキップ
EARLY_EXIT_PAGES = 20

# 区ごと並列取得のワーカー数（livable は負荷対策のため控えめに設定）
PARALLEL_WARD_WORKERS = 3


# ──────────────────────────── CSS Modules ユーティリティ ────────────────────────────


def _select_by_partial_class(soup_or_tag, base_class_name: str) -> list[Tag]:
    """CSS Modules のハッシュ付きクラス名を部分一致で検索する。
    例: base_class_name="Card_propertyCardContents" で
        class="Card_propertyCardContents___7jPF" にマッチする。
    """
    pattern = re.compile(re.escape(base_class_name))
    return soup_or_tag.find_all(class_=pattern)


def _select_one_by_partial_class(soup_or_tag, base_class_name: str) -> Optional[Tag]:
    """CSS Modules のハッシュ付きクラス名を部分一致で1つだけ検索する。"""
    pattern = re.compile(re.escape(base_class_name))
    return soup_or_tag.find(class_=pattern)


# ──────────────────────────── データクラス ────────────────────────────


@dataclass
class LivableListing:
    """東急リバブル一覧から得た1件分の項目。"""

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
    listing_agent: Optional[str] = "東急リバブル"
    is_motodzuke: Optional[bool] = True

    def to_dict(self):
        return asdict(self)


# ──────────────────────────── HTTP 取得 ────────────────────────────


def fetch_list_page(session: requests.Session, url: str) -> str:
    """一覧ページのHTMLを取得。5xx/429/タイムアウト・接続エラー時はリトライする。"""
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(LIVABLE_REQUEST_DELAY_SEC)
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


# ──────────────────────────── 価格パース（複数span対応） ────────────────────────────


def _parse_price_from_card(card: Tag) -> Optional[int]:
    """カード内の価格ブロックから価格（万円）を抽出する。

    livable の価格表示は複数の span に分かれている:
      <span class="Single_price___XXX">2</span>
      <span class="Single_unit___XXX">億</span>
      <span class="Single_price___XXX">4,800</span>
      <span class="Single_unit___XXX">万円</span>
    これらを結合して "2億4,800万円" のような文字列を作り parse_price に渡す。
    """
    price_block = _select_one_by_partial_class(card, "Card_priceBlock") or \
                  _select_one_by_partial_class(card, "Card_price") or \
                  _select_one_by_partial_class(card, "priceBlock")
    if not price_block:
        return None

    # Single_price / Single_unit の span を順に結合
    price_spans = _select_by_partial_class(price_block, "Single_price") + \
                  _select_by_partial_class(price_block, "Single_unit")

    if price_spans:
        # DOM順序を維持するため、price_block 内の全 span をイテレートする
        parts: list[str] = []
        for span in price_block.find_all("span", recursive=True):
            cls = " ".join(span.get("class", []))
            if "Single_price" in cls or "Single_unit" in cls:
                parts.append((span.get_text(strip=True) or ""))
        price_text = "".join(parts)
    else:
        # フォールバック: price ブロック全体のテキスト
        price_text = (price_block.get_text(strip=True) or "")

    return parse_price(price_text) if price_text else None


# ──────────────────────────── 詳細リスト項目のパース ────────────────────────────


def _classify_detail_item(text: str) -> tuple[str, str]:
    """Card_detailList 内の各項目テキストを分類する。

    Returns:
        (分類キー, テキスト) のタプル。分類キーは:
        "address", "station", "layout", "area", "built", "floor", "direction", "unknown"
    """
    text = text.strip()
    if not text:
        return ("unknown", text)

    # 住所: 「区」「丁目」「番地」を含む
    if re.search(r"[都道府県]|区(?!分)|丁目|番地", text):
        return ("address", text)

    # 駅・路線: 「駅」と「徒歩」を含む
    if "駅" in text and ("徒歩" in text or "分" in text):
        return ("station", text)
    # 「線」「ライン」を含み路線っぽい場合
    if "駅" in text:
        return ("station", text)

    # 間取り: 1LDK, 2DK, 3LDK+S 等
    if re.search(r"\d+[LDKS]", text):
        return ("layout", text)

    # 面積: m2 / m / ㎡ を含む
    if re.search(r"m[2²]|㎡", text, re.IGNORECASE):
        return ("area", text)

    # 築年: 「年」+（「月」or「築」）
    if re.search(r"\d{4}\s*年.*?(?:月|築)|築", text):
        return ("built", text)

    # 階: 「階」を含む（「階建」「地上」等）
    if "階" in text:
        return ("floor", text)

    # 向き: 「向き」を含む
    if "向き" in text:
        return ("direction", text)

    return ("unknown", text)


# ──────────────────────────── HTMLパース ────────────────────────────


def parse_list_html(html: str, base_url: str = BASE_URL) -> list[LivableListing]:
    """東急リバブル一覧HTMLから物件リストをパース。

    各物件は class に 'propertyCardContents' を含む div 内にあり、
    CSS Modules のハッシュ付きクラス名を部分一致で特定する。
    """
    soup = BeautifulSoup(html, "lxml")
    cards = _select_by_partial_class(soup, "propertyCardContents")
    items: list[LivableListing] = []

    for card in cards:
        # --- URL ---
        link = card.find("a", href=True)
        if not link:
            continue
        href = link.get("href", "")
        url = urljoin(base_url, href) if href else ""
        if not url:
            continue

        # --- 物件名 ---
        name = ""
        # Card_name > Heading > Card_propertyName or Card_text
        name_div = _select_one_by_partial_class(card, "Card_name")
        if name_div:
            # h2 内の span を優先
            h2 = name_div.find("h2")
            if h2:
                name_span = _select_one_by_partial_class(h2, "Card_propertyName") or \
                            _select_one_by_partial_class(h2, "Card_text")
                if name_span:
                    name = (name_span.get_text(strip=True) or "").strip()
                else:
                    name = (h2.get_text(strip=True) or "").strip()
        if not name:
            # フォールバック: propertyName クラスを直接探す
            name_el = _select_one_by_partial_class(card, "propertyName")
            if name_el:
                name = (name_el.get_text(strip=True) or "").strip()
        name = clean_listing_name(name)

        # --- 価格 ---
        price_man = _parse_price_from_card(card)

        # --- 詳細リスト ---
        address = ""
        station_line = ""
        walk_min: Optional[int] = None
        area_m2: Optional[float] = None
        layout = ""
        built_str = ""
        built_year: Optional[int] = None
        floor_position: Optional[int] = None
        floor_total: Optional[int] = None

        detail_list = _select_one_by_partial_class(card, "Card_detailList")
        if detail_list:
            detail_items = _select_by_partial_class(detail_list, "Card_item")
            for item in detail_items:
                item_text = (item.get_text(strip=True) or "").strip()
                category, text = _classify_detail_item(item_text)

                if category == "address" and not address:
                    address = text
                elif category == "station" and not station_line:
                    station_line = text
                    walk_min = parse_walk_min(text)
                elif category == "layout" and not layout:
                    # "4LDK" のようなテキストからレイアウトだけ抽出
                    m = re.search(r"\d+[LDKS]+(?:\+[A-Z])?", text)
                    layout = m.group(0) if m else text
                elif category == "area" and area_m2 is None:
                    area_m2 = parse_area_m2(text)
                elif category == "built" and built_year is None:
                    built_year = parse_built_year(text)
                    built_str = text
                elif category == "floor":
                    if floor_position is None:
                        floor_position = parse_floor_position(text)
                    if floor_total is None:
                        floor_total = parse_floor_total(text)
                        # livable では「地上12階」のような表現もある
                        if floor_total is None:
                            m = re.search(r"地上\s*(\d+)\s*階", text)
                            if m:
                                floor_total = int(m.group(1))

        # フォールバック: カード全体テキストからの補完
        card_text = card.get_text() or ""
        if walk_min is None:
            walk_min = parse_walk_min(card_text)
        if area_m2 is None:
            area_m2 = parse_area_m2(card_text)
        if built_year is None:
            built_year = parse_built_year(card_text)
        if floor_position is None:
            floor_position = parse_floor_position(card_text)
        if floor_total is None:
            floor_total = parse_floor_total(card_text)

        items.append(LivableListing(
            source="livable",
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

    if not items:
        title = soup.find("title")
        title_text = title.get_text(strip=True) if title else "(no title)"
        body_snippet = (soup.get_text()[:200] or "").replace("\n", " ")
        logger.warning(
            "livable: セレクタが0件 — HTML構造が変わった可能性があります。"
            " title=%r, body_snippet=%r",
            title_text, body_snippet,
        )

    return items


# ──────────────────────────── 条件フィルタ ────────────────────────────


def apply_conditions(listings: list[LivableListing]) -> list[LivableListing]:
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


# ──────────────────────────── 区ごとスクレイピング ────────────────────────────


def _scrape_ward(
    ward_code: str,
    ward_name: str,
    apply_filter: bool,
    limit: int,
) -> list[LivableListing]:
    """指定区の全ページをスクレイピングして LivableListing リストを返す。

    ThreadPoolExecutor から呼ばれるため、独立した session を生成する。
    """
    session = create_session()
    results: list[LivableListing] = []
    seen_urls_ward: set[str] = set()

    p = 1
    ward_total_parsed = 0
    ward_total_passed = 0
    pages_since_last_pass = 0

    while p <= limit:
        if p == 1:
            url = WARD_LIST_URL.format(ward_code=ward_code)
        else:
            url = WARD_LIST_URL_PAGE.format(ward_code=ward_code, page=p)

        try:
            html = fetch_list_page(session, url)
        except requests.exceptions.HTTPError as e:
            if e.response is not None and e.response.status_code == 404:
                # 404 は物件がない区 or ページ範囲外
                if p == 1:
                    logger.info("livable: %s (a%s) は物件なし (404)", ward_name, ward_code)
                break
            if e.response is not None and 500 <= e.response.status_code < 600:
                logger.warning(
                    "livable: %s (a%s) ページ%d で %d エラーのためスキップ",
                    ward_name, ward_code, p, e.response.status_code,
                )
                p += 1
                continue
            raise
        except Exception as e:
            logger.error("livable: %s (a%s) ページ%d 取得失敗: %s", ward_name, ward_code, p, e)
            break

        rows = parse_list_html(html)
        if not rows:
            break

        ward_total_parsed += len(rows)
        passed = 0
        for row in rows:
            if row.url and row.url not in seen_urls_ward:
                seen_urls_ward.add(row.url)
                if apply_filter:
                    filtered = apply_conditions([row])
                    if filtered:
                        results.append(filtered[0])
                        passed += 1
                        logger.debug("  -> %s (%s万)", filtered[0].name, filtered[0].price_man)
                else:
                    results.append(row)
                    passed += 1

        ward_total_passed += passed
        if passed > 0:
            pages_since_last_pass = 0
        else:
            pages_since_last_pass += 1

        if pages_since_last_pass >= EARLY_EXIT_PAGES:
            logger.info(
                "livable: %s (a%s) 早期打ち切り（%dページ連続で通過0件, 累計通過: %d件）",
                ward_name, ward_code, pages_since_last_pass, ward_total_passed,
            )
            break

        if p % 10 == 0:
            logger.info("livable: %s (a%s) ...%dページ処理済 (通過: %d件)", ward_name, ward_code, p, ward_total_passed)

        p += 1

    if ward_total_parsed > 0:
        logger.info("livable: %s (a%s) 完了 — %d件パース, %d件通過", ward_name, ward_code, ward_total_parsed, ward_total_passed)

    return results


# ──────────────────────────── メインエントリポイント ────────────────────────────


def scrape_livable(max_pages: Optional[int] = 2, apply_filter: bool = True) -> Iterator[LivableListing]:
    """東急リバブル 東京23区中古マンション一覧を取得。

    全23区を ThreadPoolExecutor で並列取得する（PARALLEL_WARD_WORKERS 区を同時処理）。
    各区内は1ページ目からページネーションし、物件が0件になるまで取得する。
    max_pages=0 のときは結果がなくなるまで全ページ取得。
    """
    limit = max_pages if max_pages and max_pages > 0 else MAX_PAGES_SAFETY

    logger.info(
        "livable: 東京23区 中古マンション取得開始（最大%dページ/区, 並列ワーカー: %d）",
        limit, PARALLEL_WARD_WORKERS,
    )

    seen_urls: set[str] = set()
    total_yielded = 0
    futures = {}

    with ThreadPoolExecutor(max_workers=PARALLEL_WARD_WORKERS) as executor:
        for ward_code, ward_name in TOKYO_23_WARD_CODES.items():
            future = executor.submit(_scrape_ward, ward_code, ward_name, apply_filter, limit)
            futures[future] = (ward_code, ward_name)

        for future in as_completed(futures):
            ward_code, ward_name = futures[future]
            try:
                ward_results = future.result()
            except Exception as e:
                logger.error("livable: %s (a%s) 並列取得エラー: %s", ward_name, ward_code, e)
                continue

            for row in ward_results:
                if row.url and row.url not in seen_urls:
                    seen_urls.add(row.url)
                    yield row
                    total_yielded += 1

    logger.info("livable: 全区完了 — 合計 %d 件", total_yielded)
