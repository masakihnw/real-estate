"""
ステップ（住友不動産販売 stepon.co.jp）中古マンション一覧のスクレイピング。

stepon.co.jp はボット検知が厳しく、通常の requests/curl では
「サーバーが混み合っています」ページが返される。
そのため Playwright（ヘッドレスブラウザ）を使用してページをレンダリングする。

サイトは Shift-JIS エンコーディングを使用。
"""

import json
import random
import re
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Iterator, Optional

from config import (
    PRICE_MIN_MAN,
    PRICE_MAX_MAN,
    AREA_MIN_M2,
    AREA_MAX_M2,
    BUILT_YEAR_MIN,
    WALK_MIN_MAX,
    TOTAL_UNITS_MIN,
    STEPON_REQUEST_DELAY_SEC,
    USER_AGENT,
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
    load_station_passengers,
    station_passengers_ok,
    line_ok,
    is_tokyo_23_by_address,
)

from logger import get_logger
logger = get_logger(__name__)

# Playwright はオプション依存: インストールされていない環境では警告を出してスキップ
try:
    from playwright.sync_api import sync_playwright, BrowserContext
    HAS_PLAYWRIGHT = True
except ImportError:
    HAS_PLAYWRIGHT = False
    logger.warning("Playwright がインストールされていません。stepon スクレイパーは無効です。")

try:
    from bs4 import BeautifulSoup
    HAS_BS4 = True
except ImportError:
    HAS_BS4 = False


BASE_URL = "https://www.stepon.co.jp"

# 東京23区・中古マンション一覧
# ページング: ?page=2, ?page=3 ... (推定)
LIST_URL_FIRST = "https://www.stepon.co.jp/mansion/tokyo/"
LIST_URL_PAGE = "https://www.stepon.co.jp/mansion/tokyo/?page={page}"

# Playwright はブラウザ起動コストが高いため安全上限を低めに設定
MAX_PAGES_SAFETY = 50
# 早期打ち切り: 連続 N ページで新規通過0件なら残りをスキップ
EARLY_EXIT_PAGES = 10


@dataclass
class SteponListing:
    """ステップ一覧から得た1件分の項目。"""

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
    listing_agent: Optional[str] = "住友不動産販売"
    is_motodzuke: Optional[bool] = True

    def to_dict(self):
        return asdict(self)


# ──────────────────────────── Playwright ────────────────────────────


def _launch_browser():
    """Playwright ブラウザを起動し、(pw, browser, context) を返す。"""
    pw = sync_playwright().start()
    browser = pw.chromium.launch(headless=True)
    context = browser.new_context(
        user_agent=USER_AGENT,
        locale="ja-JP",
        viewport={"width": 1920, "height": 1080},
        extra_http_headers={
            "Accept-Language": "ja,en;q=0.9",
            "Referer": "https://www.google.co.jp/",
        },
    )
    return pw, browser, context


def fetch_list_page_pw(context: BrowserContext, url: str, *, max_retries: int = 3) -> str:
    """Playwright でページを取得し、レンダリング済み HTML を返す。

    ボット検知時は指数バックオフ（5s→10s→20s）でリトライする。
    """
    for attempt in range(max_retries):
        page = context.new_page()
        try:
            logger.info("Stepon: ページ取得中 (attempt %d): %s", attempt + 1, url)
            page.goto(url, wait_until="domcontentloaded", timeout=45000)

            try:
                page.wait_for_selector(
                    "table, .property, .bukken, .mansion, .result, article, [class*=list]",
                    timeout=10000,
                )
            except Exception:
                logger.debug("Stepon: 物件セレクタの待機タイムアウト（コンテンツ全体は取得済み）")

            html = page.content()

            if not _is_bot_block(html):
                return html

            logger.warning("Stepon: ボット検知 (attempt %d): %s", attempt + 1, url)
        except Exception as e:
            logger.error("Stepon: ページ取得エラー (attempt %d): %s — %s", attempt + 1, url, e)
        finally:
            page.close()

        if attempt < max_retries - 1:
            backoff = (5 * (2 ** attempt)) + random.uniform(1, 3)
            logger.info("Stepon: %0.1f秒待機後にリトライ...", backoff)
            time.sleep(backoff)

    logger.error("Stepon: 全リトライ失敗: %s", url)
    return ""


def _is_bot_block(html: str) -> bool:
    """ボット検知（サーバー混雑）ページかどうかを判定。"""
    if not html:
        return True
    # stepon.co.jp のボット検知は「サーバーが混み合っています」を返す
    if "サーバーが混み合っています" in html:
        return True
    # ページが極端に短い場合もブロックの可能性
    if len(html) < 1000 and "mansion" not in html.lower():
        return True
    return False


# ──────────────────────────── HTML パーサー ────────────────────────────


def parse_list_html(html: str) -> list[SteponListing]:
    """ステップ一覧 HTML から物件リストをパース。

    実際の HTML 構造が不明なため、複数のセレクタパターンを試行する。
    1. カード型セレクタ（div.property-card 等）
    2. テーブル型セレクタ
    3. テキストベースの正規表現フォールバック
    """
    if not html or not HAS_BS4:
        return []

    soup = BeautifulSoup(html, "lxml")
    items: list[SteponListing] = []

    # --- 戦略1: カード型セレクタを複数試行 ---
    card_selectors = [
        "div.property-card",
        "div.bukken-list",
        "div.result-item",
        "div.mansion-item",
        "div.search-result",
        "div.estate-list",
        "li.property-card",
        "li.bukken-list",
        "li.result-item",
        "article.property",
        "article.bukken",
        "div[class*='bukken']",
        "div[class*='property']",
        "div[class*='mansion']",
        "div[class*='result-item']",
        "div[class*='estate']",
    ]

    for selector in card_selectors:
        cards = soup.select(selector)
        if not cards:
            continue
        logger.info("Stepon: セレクタ '%s' で %d 件のカードを検出", selector, len(cards))
        for card in cards:
            listing = _parse_card(card)
            if listing:
                items.append(listing)
        if items:
            return items

    # --- 戦略2: テーブルベースの抽出 ---
    items = _parse_table_based(soup)
    if items:
        logger.info("Stepon: テーブルベースで %d 件を抽出", len(items))
        return items

    # --- 戦略3: リンク + 周辺テキストベースの抽出 ---
    items = _parse_link_based(soup)
    if items:
        logger.info("Stepon: リンクベースで %d 件を抽出", len(items))
        return items

    # --- 戦略4: テキストベースの正規表現フォールバック ---
    items = _parse_text_fallback(soup)
    if items:
        logger.info("Stepon: テキストフォールバックで %d 件を抽出", len(items))
        return items

    # 全セレクタ失敗
    title = soup.find("title")
    title_text = title.get_text(strip=True) if title else "(no title)"
    body_snippet = (soup.get_text()[:300] or "").replace("\n", " ").strip()
    logger.warning(
        "Stepon: 全セレクタが0件 — HTML構造が変わった可能性があります。"
        " title=%r, body_snippet=%r",
        title_text, body_snippet[:200],
    )
    return []


def _parse_card(card) -> Optional[SteponListing]:
    """カード型要素から物件情報を抽出。"""
    text = (card.get_text(separator="\n") or "").strip()
    if not text:
        return None

    # URL: カード内のリンクから物件詳細 URL を取得
    url = ""
    link = card.find("a", href=True)
    if link:
        href = link.get("href", "")
        if href.startswith("http"):
            url = href
        elif href.startswith("/"):
            url = BASE_URL + href

    # 物件名: h2/h3/h4 またはリンクテキスト
    name = ""
    for tag in ("h2", "h3", "h4", "h5"):
        el = card.find(tag)
        if el:
            raw = (el.get_text(strip=True) or "").strip()
            cleaned = clean_listing_name(raw)
            if cleaned:
                name = cleaned
                break
    if not name and link:
        lt = (link.get_text(strip=True) or "").strip()
        if lt and len(lt) > 3:
            name = clean_listing_name(lt)

    # テーブルセルからの情報抽出
    info = _extract_table_values(card)
    address = info.get("address", "")
    station_line = info.get("station_line", "")
    layout = info.get("layout", "")
    area_str = info.get("area", "")
    price_str = info.get("price", "")
    built_str = info.get("built", "")
    total_units_str = info.get("total_units", "")
    floor_str = info.get("floor", "")

    # テキスト全体からのフォールバック抽出
    price_man = parse_price(price_str) if price_str else None
    if price_man is None:
        price_man = _extract_price_from_text(text)

    area_m2 = parse_area_m2(area_str) if area_str else None
    if area_m2 is None:
        area_m2 = parse_area_m2(text)

    walk_min = parse_walk_min(station_line) if station_line else None
    if walk_min is None:
        walk_min = parse_walk_min(text)

    built_year = parse_built_year(built_str) if built_str else None
    if built_year is None:
        built_year = parse_built_year(text)
    if not built_str and built_year:
        built_str = f"{built_year}年"

    total_units = parse_total_units_strict(total_units_str) if total_units_str else None
    if total_units is None:
        total_units = parse_total_units_strict(text)

    floor_position = parse_floor_position(floor_str) if floor_str else None
    if floor_position is None:
        floor_position = parse_floor_position(text)

    floor_total = parse_floor_total(floor_str) if floor_str else None
    if floor_total is None:
        floor_total = parse_floor_total(text)

    # 住所のフォールバック: テキストから東京都で始まる住所を抽出
    if not address:
        address = _extract_address_from_text(text)

    # 駅・路線のフォールバック
    if not station_line:
        station_line = _extract_station_from_text(text)

    # 間取りのフォールバック
    if not layout:
        layout = _extract_layout_from_text(text)

    if not name and not url:
        return None

    return SteponListing(
        source="stepon",
        url=url,
        name=name or "",
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
    )


def _extract_table_values(container) -> dict[str, str]:
    """コンテナ内のテーブル (th/td または dt/dd) から物件情報を抽出。"""
    info: dict[str, str] = {}

    # ラベル → info キーのマッピング
    label_map = {
        "価格": "price",
        "販売価格": "price",
        "所在地": "address",
        "住所": "address",
        "交通": "station_line",
        "沿線": "station_line",
        "最寄駅": "station_line",
        "間取り": "layout",
        "間取": "layout",
        "専有面積": "area",
        "面積": "area",
        "築年月": "built",
        "築年": "built",
        "完成年月": "built",
        "建築年月": "built",
        "総戸数": "total_units",
        "所在階": "floor",
        "階数": "floor",
        "階": "floor",
    }

    # th/td パターン
    for table in container.find_all("table"):
        for tr in table.find_all("tr"):
            ths = tr.find_all("th")
            tds = tr.find_all("td")
            for i, th in enumerate(ths):
                th_text = (th.get_text(strip=True) or "").strip()
                for label, key in label_map.items():
                    if label in th_text:
                        if i < len(tds):
                            val = (tds[i].get_text(strip=True) or "").strip()
                            if val and key not in info:
                                info[key] = val
                        break

    # dt/dd パターン（フォールバック）
    if len(info) < 3:
        for dl in container.find_all("dl"):
            dts = dl.find_all("dt")
            dds = dl.find_all("dd")
            for i, dt in enumerate(dts):
                dt_text = (dt.get_text(strip=True) or "").strip()
                for label, key in label_map.items():
                    if label in dt_text:
                        if i < len(dds):
                            val = (dds[i].get_text(strip=True) or "").strip()
                            if val and key not in info:
                                info[key] = val
                        break

    return info


def _parse_table_based(soup) -> list[SteponListing]:
    """ページ全体からテーブル行ベースで物件を抽出。

    不動産サイトの多くは物件情報をテーブル（<table>）で表示する。
    各行の th/td ペアから情報を取得する。
    """
    items: list[SteponListing] = []

    # 物件詳細へのリンクを含むテーブルを探す
    for table in soup.find_all("table"):
        text = (table.get_text() or "")
        # 物件テーブルの判定: 価格と面積の両方が含まれるか
        if "万円" not in text:
            continue
        if "m" not in text.lower() and "㎡" not in text:
            continue

        # このテーブル内のリンクから物件を抽出
        links = table.find_all("a", href=True)
        for link in links:
            href = link.get("href", "")
            # 物件詳細らしいリンクのみ
            if not href or href == "#":
                continue
            if href.startswith("http"):
                url = href
            elif href.startswith("/"):
                url = BASE_URL + href
            else:
                continue

            # リンクの親行（tr）から情報を取得
            tr = link.find_parent("tr")
            if not tr:
                continue

            row_text = (tr.get_text(separator="\n") or "").strip()
            if "万円" not in row_text:
                continue

            name = clean_listing_name((link.get_text(strip=True) or "").strip())
            price_man = _extract_price_from_text(row_text)
            area_m2 = parse_area_m2(row_text)
            walk_min = parse_walk_min(row_text)
            built_year = parse_built_year(row_text)
            layout = _extract_layout_from_text(row_text)
            address = _extract_address_from_text(row_text)
            station_line = _extract_station_from_text(row_text)
            total_units = parse_total_units_strict(row_text)
            floor_position = parse_floor_position(row_text)
            floor_total = parse_floor_total(row_text)

            if name or url:
                items.append(SteponListing(
                    source="stepon",
                    url=url,
                    name=name or "",
                    price_man=price_man,
                    address=address,
                    station_line=station_line,
                    walk_min=walk_min,
                    area_m2=area_m2,
                    layout=layout,
                    built_str=f"{built_year}年" if built_year else "",
                    built_year=built_year,
                    total_units=total_units,
                    floor_position=floor_position,
                    floor_total=floor_total,
                ))

    return items


def _parse_link_based(soup) -> list[SteponListing]:
    """物件詳細リンクを起点に、周辺のコンテナから情報を抽出。"""
    items: list[SteponListing] = []
    seen_urls: set[str] = set()

    # /mansion/ パスを含むリンクを探す（物件詳細ページへのリンク）
    detail_links = soup.find_all("a", href=re.compile(r"/mansion/.*\d"))
    for link in detail_links:
        href = link.get("href", "")
        if href.startswith("http"):
            url = href
        elif href.startswith("/"):
            url = BASE_URL + href
        else:
            continue

        if url in seen_urls:
            continue

        # リンクを含む最も近い意味のあるコンテナを探す
        container = link
        for _ in range(15):
            container = container.parent
            if container is None or container.name in ("body", "html", "[document]"):
                container = None
                break
            text = container.get_text() or ""
            # 価格と面積の両方を含むブロックを探す
            if "万円" in text and ("m" in text.lower() or "㎡" in text):
                break

        if container is None:
            continue

        seen_urls.add(url)
        text = (container.get_text(separator="\n") or "").strip()

        # 物件名
        name = ""
        for tag in ("h2", "h3", "h4", "h5"):
            el = container.find(tag)
            if el:
                raw = (el.get_text(strip=True) or "").strip()
                cleaned = clean_listing_name(raw)
                if cleaned:
                    name = cleaned
                    break
        if not name:
            lt = (link.get_text(strip=True) or "").strip()
            if lt and len(lt) > 3:
                name = clean_listing_name(lt)

        # テーブル値を優先的に抽出
        info = _extract_table_values(container)

        price_man = parse_price(info.get("price", "")) if info.get("price") else _extract_price_from_text(text)
        area_m2 = parse_area_m2(info.get("area", "")) if info.get("area") else parse_area_m2(text)
        walk_min = parse_walk_min(info.get("station_line", "")) if info.get("station_line") else parse_walk_min(text)
        built_str = info.get("built", "")
        built_year = parse_built_year(built_str) if built_str else parse_built_year(text)
        if not built_str and built_year:
            built_str = f"{built_year}年"
        layout = info.get("layout", "") or _extract_layout_from_text(text)
        address = info.get("address", "") or _extract_address_from_text(text)
        station_line = info.get("station_line", "") or _extract_station_from_text(text)
        total_units = parse_total_units_strict(info.get("total_units", "")) if info.get("total_units") else parse_total_units_strict(text)
        floor_position = parse_floor_position(text)
        floor_total = parse_floor_total(text)

        items.append(SteponListing(
            source="stepon",
            url=url,
            name=name or "",
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
        ))

    return items


def _parse_text_fallback(soup) -> list[SteponListing]:
    """最終フォールバック: ページ全体のテキストから物件情報ブロックを正規表現で抽出。

    「万円」を含むテキストブロックを物件情報として切り出す。
    """
    items: list[SteponListing] = []
    full_text = soup.get_text(separator="\n")
    if not full_text:
        return []

    # 「万円」を含む行を起点に、前後の行から物件情報を収集
    lines = full_text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if "万円" not in line:
            i += 1
            continue

        # この行を中心に前後20行のコンテキストを収集
        start = max(0, i - 10)
        end = min(len(lines), i + 10)
        context = "\n".join(lines[start:end])

        price_man = _extract_price_from_text(line)
        if price_man is None:
            i += 1
            continue

        area_m2 = parse_area_m2(context)
        walk_min = parse_walk_min(context)
        built_year = parse_built_year(context)
        layout = _extract_layout_from_text(context)
        address = _extract_address_from_text(context)
        station_line = _extract_station_from_text(context)
        total_units = parse_total_units_strict(context)
        floor_position = parse_floor_position(context)
        floor_total = parse_floor_total(context)

        # 最低限の情報があれば物件として採用
        if price_man and (area_m2 or layout):
            items.append(SteponListing(
                source="stepon",
                url="",
                name=address or "",
                price_man=price_man,
                address=address,
                station_line=station_line,
                walk_min=walk_min,
                area_m2=area_m2,
                layout=layout,
                built_str=f"{built_year}年" if built_year else "",
                built_year=built_year,
                total_units=total_units,
                floor_position=floor_position,
                floor_total=floor_total,
            ))

        # 同じ物件を重複抽出しないようスキップ
        i = end
    return items


# ──────────────────────────── テキスト抽出ヘルパー ────────────────────────────


def _extract_price_from_text(text: str) -> Optional[int]:
    """テキストから価格（万円）を抽出。parse_utils.parse_price のラッパー。"""
    return parse_price(text)


def _extract_address_from_text(text: str) -> str:
    """テキストから住所を抽出。"""
    if not text:
        return ""
    # 「東京都○○区...」パターン
    m = re.search(r"(東京都[^\n\r,、]{3,30})", text)
    if m:
        return m.group(1).strip()
    return ""


def _extract_station_from_text(text: str) -> str:
    """テキストから最寄り駅情報を抽出。"""
    if not text:
        return ""
    # 「○○線「○○」駅 徒歩N分」パターン
    m = re.search(r"([^\s\n]+線\s*[「『]?[^\s」』\n]+[」』]?\s*駅?\s*徒歩\s*約?\s*\d+\s*分)", text)
    if m:
        return m.group(1).strip()
    # 「○○駅 徒歩N分」パターン
    m = re.search(r"([^\s\n]+駅\s*徒歩\s*約?\s*\d+\s*分)", text)
    if m:
        return m.group(1).strip()
    # 「○○駅」のみ
    m = re.search(r"([^\s\n]+駅)", text)
    if m:
        return m.group(1).strip()
    return ""


def _extract_layout_from_text(text: str) -> str:
    """テキストから間取り（2LDK 等）を抽出。"""
    if not text:
        return ""
    m = re.search(r"(\d[LDKS]+(?:\+S)?)", text)
    if m:
        return m.group(1).strip()
    return ""


# ──────────────────────────── フィルタ ────────────────────────────


def apply_conditions(listings: list[SteponListing]) -> list[SteponListing]:
    """価格・専有・間取り・築年・徒歩・地域（東京23区）・路線・総戸数・駅乗降客数でフィルタ。"""
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


# ──────────────────────────── メインスクレイパー ────────────────────────────


def scrape_stepon(
    max_pages: Optional[int] = 2,
    apply_filter: bool = True,
) -> Iterator[SteponListing]:
    """ステップ（住友不動産販売）東京中古マンション一覧を取得。

    max_pages=0 のときは結果がなくなるまで全ページ取得。

    Playwright が未インストールの場合は警告を出して何も返さない。
    """
    if not HAS_PLAYWRIGHT:
        logger.warning("Stepon: Playwright がインストールされていないためスキップします。")
        return

    limit = max_pages if max_pages and max_pages > 0 else MAX_PAGES_SAFETY
    pw, browser, context = _launch_browser()
    try:
        page_num = 1
        total_parsed = 0
        total_passed = 0
        pages_since_last_pass = 0

        while page_num <= limit:
            url = LIST_URL_FIRST if page_num == 1 else LIST_URL_PAGE.format(page=page_num)

            # ページ間のディレイ（初回以外）— ランダム化でボット検知回避
            if page_num > 1:
                time.sleep(STEPON_REQUEST_DELAY_SEC + random.uniform(1, 3))

            html = fetch_list_page_pw(context, url)
            if not html:
                logger.info("Stepon: ページ%dで空HTML。ボット検知またはページ終端の可能性。", page_num)
                break

            rows = parse_list_html(html)
            if not rows:
                logger.info(
                    "Stepon: ページ%dで0件パース。一覧のHTML構造が変わったか、最終ページの可能性。",
                    page_num,
                )
                break

            total_parsed += len(rows)
            passed = 0

            for row in rows:
                if apply_filter:
                    filtered = apply_conditions([row])
                    if filtered:
                        yield filtered[0]
                        passed += 1
                        logger.debug("  OK: %s (%s万)", filtered[0].name, filtered[0].price_man)
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
                logger.info(
                    "Stepon: 早期打ち切り（%dページ連続で通過0件, 累計通過: %d件）",
                    pages_since_last_pass, total_passed,
                )
                break

            # 進捗ログ: 5ページごと（Playwright は遅いため頻度を上げる）
            if page_num % 5 == 0:
                logger.info("Stepon: ...%dページ処理済 (通過: %d件)", page_num, total_passed)

            page_num += 1

        if total_parsed > 0:
            logger.info("Stepon: 完了 — %d件パース, %d件通過", total_parsed, total_passed)
        else:
            logger.warning("Stepon: 物件を1件もパースできませんでした。")
    finally:
        browser.close()
        pw.stop()


# ──────────────────────────── 詳細ページ ────────────────────────────

_DETAIL_CACHE_PATH = Path(__file__).resolve().parent / "data" / "detail_cache_stepon.json"
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


def _fetch_detail_page_pw(context, url: str) -> str:
    """Playwright で詳細ページを取得。"""
    page = context.new_page()
    try:
        page.goto(url, wait_until="domcontentloaded", timeout=45000)
        try:
            page.wait_for_selector("table, dl, .detail, .bukken-detail", timeout=10000)
        except Exception:
            pass
        return page.content()
    except Exception as e:
        logger.error("Stepon detail: ページ取得エラー: %s — %s", url, e)
        return ""
    finally:
        page.close()


def parse_stepon_detail_html(html: str, url: str = "") -> dict:
    """ステップ物件詳細ページから追加情報を抽出。"""
    result: dict = {
        "management_fee": None,
        "repair_reserve_fund": None,
        "ownership": None,
        "total_units": None,
        "floor_plan_images": None,
        "suumo_images": None,
    }
    if not html or not HAS_BS4:
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
        if "stepon" not in src and not src.startswith("/"):
            continue
        if src.startswith("/"):
            src = BASE_URL + src

        seen_urls.add(src)
        if "間取" in alt:
            floor_plan_images.append(src)
        elif "/photo/" in src or "/image/" in src or "/bukken/" in src:
            suumo_images.append({"url": src, "label": alt or "外観"})

    if floor_plan_images:
        result["floor_plan_images"] = floor_plan_images
    if suumo_images:
        result["suumo_images"] = suumo_images

    return result


def enrich_stepon_listings(listings: list[SteponListing]) -> list[SteponListing]:
    """フィルタ通過済みリストの各物件の詳細ページを取得し、追加情報を注入する。"""
    if not listings or not HAS_PLAYWRIGHT:
        return listings

    cache = _load_detail_cache()
    enriched_count = 0

    pw, browser, context = _launch_browser()
    try:
        for listing in listings:
            cached = cache.get(listing.url)
            if cached:
                detail = cached
            else:
                time.sleep(STEPON_REQUEST_DELAY_SEC + random.uniform(1, 3))
                html = _fetch_detail_page_pw(context, listing.url)
                detail = parse_stepon_detail_html(html, listing.url)
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
            if enriched_count % 5 == 0:
                logger.info("Stepon detail: %d/%d件取得済", enriched_count, len(listings))
    finally:
        browser.close()
        pw.stop()

    _save_detail_cache(cache)
    logger.info("Stepon detail: 完了 — %d件エンリッチ", enriched_count)
    return listings
