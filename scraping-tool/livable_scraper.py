"""
東急リバブル（livable.co.jp）中古マンション一覧のスクレイピング。
利用規約を遵守し、負荷軽減・私的利用に留めること。
一覧は CSS Modules（ハッシュ付きクラス名）を使用しているため、
ベースクラス名の部分一致で要素を特定する。
区ごとに並列取得し、各区をページネーションする。
"""

import json
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Iterator, Optional
from urllib.parse import unquote, urljoin

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
    management_fee: Optional[int] = None
    repair_reserve_fund: Optional[int] = None
    ownership: Optional[str] = None
    suumo_images: Optional[list] = None  # [{"url": "...", "label": "..."}, ...]
    floor_plan_images: Optional[list] = None  # ["url1", "url2", ...]
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


# ──────────────────────────── 詳細ページ取得・パース ────────────────────────────


DETAIL_CACHE_PATH = Path(__file__).resolve().parent / "data" / "detail_cache_livable.json"
DETAIL_CACHE_EXPIRY_DAYS = 90


def _load_detail_cache() -> dict[str, dict]:
    """詳細キャッシュファイルを読み込む。"""
    if DETAIL_CACHE_PATH.exists():
        try:
            return json.loads(DETAIL_CACHE_PATH.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def _save_detail_cache(cache: dict[str, dict]) -> None:
    """詳細キャッシュファイルを保存する。"""
    DETAIL_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    DETAIL_CACHE_PATH.write_text(
        json.dumps(cache, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def _is_detail_cache_valid(entry: dict) -> bool:
    """キャッシュエントリが有効期限内か判定する。"""
    cached_at = entry.get("cached_at")
    if not cached_at:
        return False
    try:
        dt = datetime.fromisoformat(cached_at)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - dt).days < DETAIL_CACHE_EXPIRY_DAYS
    except (ValueError, TypeError):
        return False


def _fetch_detail_page(session: requests.Session, url: str) -> str:
    """livable 詳細ページの HTML を取得する。リトライ付き。"""
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(LIVABLE_REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                backoff = min(retry_after, 120)
                logger.warning(
                    "livable detail: 429 Rate Limited, waiting %ds (attempt %d/%d)",
                    backoff, attempt + 1, REQUEST_RETRIES,
                )
                time.sleep(backoff)
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
        except requests.exceptions.HTTPError as e:
            if e.response is not None and e.response.status_code in (500, 502, 503) and attempt < REQUEST_RETRIES - 1:
                last_error = e
                backoff = min(2 ** (attempt + 1), 30)
                logger.warning(
                    "livable detail: HTTP %d, retrying in %ds (attempt %d/%d)",
                    e.response.status_code, backoff, attempt + 1, REQUEST_RETRIES,
                )
                time.sleep(backoff)
            else:
                raise
        except (requests.exceptions.ReadTimeout, requests.exceptions.ConnectTimeout, requests.exceptions.ConnectionError) as e:
            last_error = e
            if attempt < REQUEST_RETRIES - 1:
                backoff = min(2 ** (attempt + 1), 30)
                logger.warning(
                    "livable detail: %s, retrying in %ds (attempt %d/%d)",
                    type(e).__name__, backoff, attempt + 1, REQUEST_RETRIES,
                )
                time.sleep(backoff)
            else:
                raise last_error
    if last_error is not None:
        raise last_error
    raise RuntimeError(f"全 {REQUEST_RETRIES} 回のリトライが失敗しました: {url}")


def parse_livable_detail_html(html: str, url: str = "") -> dict:
    """livable 詳細ページ HTML をパースして物件情報辞書を返す。

    Returns:
        {
            "management_fee": int or None,
            "repair_reserve_fund": int or None,
            "ownership": str or None,
            "total_units": int or None,
            "floor_plan_images": ["url1", ...] or None,
            "suumo_images": [{"url": "...", "label": "..."}, ...] or None,
        }
    """
    soup = BeautifulSoup(html, "lxml")
    result: dict = {
        "management_fee": None,
        "repair_reserve_fund": None,
        "ownership": None,
        "total_units": None,
        "area_m2": None,
        "floor_position": None,
        "floor_total": None,
        "floor_plan_images": None,
        "suumo_images": None,
    }

    # --- テーブルから物件情報を抽出 ---
    # livable の詳細ページは th/td ペアのテーブルで物件情報を表示
    for th in soup.find_all("th"):
        th_text = (th.get_text(strip=True) or "").strip()
        td = th.find_next_sibling("td")
        if not td:
            # dt/dd パターンにもフォールバック
            td = th.find_next("td")
        if not td:
            continue
        td_text = (td.get_text(strip=True) or "").strip()

        if "管理費" in th_text and "修繕" not in th_text:
            result["management_fee"] = parse_monthly_yen(td_text)
        elif "修繕積立金" in th_text or "修繕積立" in th_text:
            result["repair_reserve_fund"] = parse_monthly_yen(td_text)
        elif "権利" in th_text or "土地権利" in th_text:
            # 所有権 / 借地権 / 定期借地権 etc
            m = re.search(r"(所有権|借地権|底地権|普通借地権|定期借地権)", td_text)
            if m:
                result["ownership"] = m.group(1)
        elif "総戸数" in th_text:
            m = re.search(r"(\d+)\s*戸?", td_text)
            if m:
                result["total_units"] = int(m.group(1))
        elif "専有面積" in th_text:
            result["area_m2"] = parse_area_m2(td_text)
        elif "所在階" in th_text or ("階" in th_text and "建" in th_text and "総戸" not in th_text):
            result["floor_position"] = parse_floor_position(td_text)
            m = re.search(r"地上\s*(\d+)\s*階", td_text)
            if m:
                result["floor_total"] = int(m.group(1))
            else:
                result["floor_total"] = parse_floor_total(td_text)

    # --- dl > dt/dd パターンにも対応 ---
    for dt in soup.find_all("dt"):
        dt_text = (dt.get_text(strip=True) or "").strip()
        dd = dt.find_next_sibling("dd")
        if not dd:
            continue
        dd_text = (dd.get_text(strip=True) or "").strip()

        if "管理費" in dt_text and "修繕" not in dt_text:
            if result["management_fee"] is None:
                result["management_fee"] = parse_monthly_yen(dd_text)
        elif "修繕積立金" in dt_text or "修繕積立" in dt_text:
            if result["repair_reserve_fund"] is None:
                result["repair_reserve_fund"] = parse_monthly_yen(dd_text)
        elif "権利" in dt_text or "土地権利" in dt_text:
            if result["ownership"] is None:
                m = re.search(r"(所有権|借地権|底地権|普通借地権|定期借地権)", dd_text)
                if m:
                    result["ownership"] = m.group(1)
        elif "総戸数" in dt_text:
            if result["total_units"] is None:
                m = re.search(r"(\d+)\s*戸?", dd_text)
                if m:
                    result["total_units"] = int(m.group(1))
        elif "専有面積" in dt_text:
            if result["area_m2"] is None:
                result["area_m2"] = parse_area_m2(dd_text)
        elif "所在階" in dt_text or ("階" in dt_text and "建" in dt_text and "総戸" not in dt_text):
            if result["floor_position"] is None:
                result["floor_position"] = parse_floor_position(dd_text)
            if result["floor_total"] is None:
                m = re.search(r"地上\s*(\d+)\s*階", dd_text)
                if m:
                    result["floor_total"] = int(m.group(1))
                else:
                    result["floor_total"] = parse_floor_total(dd_text)

    # --- 画像の抽出 ---
    floor_plan_imgs: list[str] = []
    all_images: list[dict] = []
    seen_urls: set[str] = set()

    _EXCLUDE_SRC_PARTS = ("/logo", "/icon", "/btn", "/spacer", "/common/",
                          "/header/", "/nav/", "/global/", "/_assets/",
                          "/templates/", "/features/")

    for img in soup.find_all("img"):
        src = (img.get("data-src") or img.get("src") or "").strip()
        if not src or src.startswith("data:"):
            continue

        img_url = urljoin(url or BASE_URL, src)
        if img_url in seen_urls:
            continue

        alt = (img.get("alt") or "").strip()
        src_lower = src.lower()

        # SVG/アイコン/サイト共通画像を除外
        src_decoded = unquote(src_lower)
        if src.endswith(".svg") or any(x in src_decoded for x in _EXCLUDE_SRC_PARTS):
            continue
        width = img.get("width")
        height = img.get("height")
        if width and height:
            try:
                if int(width) < 50 or int(height) < 50:
                    continue
            except (ValueError, TypeError):
                pass

        # livable 画像: img.livable.co.jp/?url=...rue_image/{category}/...
        # 間取り図: URL に /layout/ or %2Flayout%2F を含む
        is_layout = "/layout/" in src_lower or "%2flayout%2f" in src_lower
        if is_layout or "間取" in alt or "madori" in src_lower or "floor_plan" in src_lower:
            if img_url not in floor_plan_imgs:
                floor_plan_imgs.append(img_url)
            seen_urls.add(img_url)
            continue

        # 物件画像: rue_image 内の photo/misc 等
        is_property_img = ("rue_image" in src_lower or "rue_image" in img_url.lower() or
                           re.search(r"(?:/|%2[fF])(?:photo|misc|image|bukken|property|mansion|room|view|gaikan)(?:/|%2[fF])", src, re.IGNORECASE))
        if is_property_img:
            all_images.append({"url": img_url, "label": alt or ""})
            seen_urls.add(img_url)
        elif re.search(r"間取|外観|内装|リビング|キッチン|バス|トイレ|洋室|和室|バルコニー|眺望", alt):
            all_images.append({"url": img_url, "label": alt})
            seen_urls.add(img_url)

    # 間取りが HTML から見つからない場合、URLパターンから推定
    if not floor_plan_imgs and url:
        m = re.search(r"/mansion/([A-Za-z0-9]+)/?", url)
        if m:
            prop_id = m.group(1)
            inferred_url = f"https://www.livable.co.jp/rue_image/layout/{prop_id}.gif"
            try:
                head_r = requests.head(inferred_url, timeout=5, allow_redirects=True,
                                       headers={"User-Agent": "Mozilla/5.0"})
                if head_r.status_code == 200:
                    floor_plan_imgs.append(inferred_url)
                    logger.debug(f"livable: 間取り推定成功 {prop_id}")
                else:
                    logger.debug(f"livable: 間取り推定失敗 {prop_id} status={head_r.status_code}")
            except Exception as e:
                logger.debug(f"livable: 間取り推定エラー {prop_id}: {e}")

    if floor_plan_imgs:
        result["floor_plan_images"] = floor_plan_imgs
    if all_images:
        result["suumo_images"] = all_images

    return result


def _merge_detail_into_listing(listing: LivableListing, detail: dict) -> None:
    """詳細ページ由来の値で listing の不足フィールドを補完する。"""
    if listing.management_fee is None and detail.get("management_fee") is not None:
        listing.management_fee = detail["management_fee"]
    if listing.repair_reserve_fund is None and detail.get("repair_reserve_fund") is not None:
        listing.repair_reserve_fund = detail["repair_reserve_fund"]
    if listing.ownership is None and detail.get("ownership") is not None:
        listing.ownership = detail["ownership"]
    if listing.total_units is None and detail.get("total_units") is not None:
        listing.total_units = detail["total_units"]
    if detail.get("area_m2") is not None:
        listing.area_m2 = detail["area_m2"]
    if listing.floor_position is None and detail.get("floor_position") is not None:
        listing.floor_position = detail["floor_position"]
    if listing.floor_total is None and detail.get("floor_total") is not None:
        listing.floor_total = detail["floor_total"]
    if listing.floor_plan_images is None and detail.get("floor_plan_images") is not None:
        listing.floor_plan_images = detail["floor_plan_images"]
    if listing.suumo_images is None and detail.get("suumo_images") is not None:
        listing.suumo_images = detail["suumo_images"]


def enrich_livable_listings(
    listings: list[LivableListing],
    session: Optional[requests.Session] = None,
) -> list[LivableListing]:
    """各 listing の詳細ページを取得して管理費・修繕積立金・権利形態・総戸数・画像を補完する。

    キャッシュ付き。90日で期限切れ。
    """
    if not listings:
        return listings

    if session is None:
        session = create_session()

    cache = _load_detail_cache()
    fetched_count = 0
    cache_hit_count = 0

    logger.info("livable detail: %d件の詳細ページ取得を開始", len(listings))

    for i, listing in enumerate(listings):
        url = listing.url
        if not url:
            continue

        # キャッシュチェック
        cached_entry = cache.get(url)
        if cached_entry and _is_detail_cache_valid(cached_entry):
            _merge_detail_into_listing(listing, cached_entry)
            cache_hit_count += 1
            continue

        # 詳細ページ取得
        try:
            html = _fetch_detail_page(session, url)
            detail = parse_livable_detail_html(html, url)
        except Exception as e:
            logger.warning("livable detail: 詳細取得失敗: %s (%s)", url, e)
            # 失敗時も空エントリでキャッシュして再取得を抑止
            cache[url] = {"cached_at": datetime.now(timezone.utc).isoformat()}
            continue

        # キャッシュ保存
        detail["cached_at"] = datetime.now(timezone.utc).isoformat()
        cache[url] = detail
        _merge_detail_into_listing(listing, detail)
        fetched_count += 1

        if (fetched_count) % 10 == 0:
            logger.info("livable detail: %d件取得済（キャッシュ: %d件）", fetched_count, cache_hit_count)
            # 中間保存
            _save_detail_cache(cache)

    _save_detail_cache(cache)
    logger.info(
        "livable detail: 完了 — 取得: %d件, キャッシュヒット: %d件, 合計: %d件",
        fetched_count, cache_hit_count, len(listings),
    )

    return listings
