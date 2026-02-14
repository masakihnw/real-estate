"""
HOME'S（LIFULL HOME'S）中古マンション一覧のスクレイピング。
利用規約: terms-check.md を参照。規約上明示的クローラー禁止はないが、
負荷軽減・私的利用に留めること。
一覧は JSON-LD (ItemList) と HTML (mod-mergeBuilding--sale / mod-listKks) の両方から取得。
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
    BUILT_YEAR_MIN,
    WALK_MIN_MAX,
    TOTAL_UNITS_MIN,
    STATION_PASSENGERS_MIN,
    ALLOWED_LINE_KEYWORDS,
    HOMES_REQUEST_DELAY_SEC,
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
    parse_total_units_strict,
    parse_monthly_yen,
    layout_ok,
    parse_ownership,
)
from report_utils import clean_listing_name
from scraper_common import (
    create_session,
    is_waf_challenge,
    load_station_passengers,
    station_passengers_ok,
    line_ok,
    is_tokyo_23_by_address,
)

BASE_URL = "https://www.homes.co.jp"

# 東京23区・中古マンション一覧（全ページ /tokyo/23ku/list/?page=N）
# ※2026年2月確認: /tokyo/23ku/ はナビゲーションページに変更されたため /list/ パスを使用
LIST_URL_FIRST = "https://www.homes.co.jp/mansion/chuko/tokyo/23ku/list/"
LIST_URL_PAGE = "https://www.homes.co.jp/mansion/chuko/tokyo/23ku/list/?page={page}"
# 全ページ取得時の安全上限（無限ループ防止）
HOMES_MAX_PAGES_SAFETY = 100

# 早期打ち切り: 連続 N ページで新規通過0件なら残りをスキップ
HOMES_EARLY_EXIT_PAGES = 20

# スクレイピング全体のタイムリミット（秒）。HOME'S は WAF が厳しく、
# 1ページに最大7分（WAF リトライ30+60+90+120秒）かかることがあるため、
# 全体の実行時間を制限して CI/CD パイプライン全体のタイムアウトを防ぐ。
HOMES_SCRAPE_TIMEOUT_SEC = 30 * 60  # 30分


@dataclass
class HomesListing:
    """HOME'S 一覧から得た1件分の項目。"""

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
    total_units: Optional[int] = None  # 総戸数（一覧の textFeatureComment などから取得）
    floor_position: Optional[int] = None   # 所在階（何階）
    floor_total: Optional[int] = None     # 建物階数（何階建て）
    ownership: Optional[str] = None        # 権利形態（所有権・借地権等。一覧に表示されていれば取得）
    management_fee: Optional[int] = None   # 管理費（円/月）
    repair_reserve_fund: Optional[int] = None  # 修繕積立金（円/月）

    def to_dict(self):
        return asdict(self)


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
    raise RuntimeError(f"全リトライが失敗しました (WAF/Rate Limited): {url}")


def _parse_jsonld_itemlist(html: str) -> list[dict[str, Any]]:
    """JSON-LD の ItemList から物件の url/name/price_man/area_m2/built_year/address を抽出。"""
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
                offer = item.get("offers") or {}
                if isinstance(offer, list):
                    offer = offer[0] if offer else {}
                io = offer.get("itemOffered") or {}
                addr = io.get("address") or {}
                name = (item.get("name") or "").strip()
                url = (item.get("url") or "").strip()
                if not url:
                    continue
                price = offer.get("price")
                price_man = int(price) // 10000 if price is not None else None
                fs = io.get("floorSize") or {}
                area_m2 = float(fs["value"]) if fs.get("value") is not None else None
                built_year = io.get("yearBuilt")
                built_year = int(built_year) if built_year is not None else None
                address = (addr.get("name") or "").strip()
                built_str = f"{built_year}年" if built_year else ""
                out.append({
                    "url": url,
                    "name": name,
                    "price_man": price_man,
                    "area_m2": area_m2,
                    "built_year": built_year,
                    "built_str": built_str,
                    "address": address,
                })
            return out
        except (json.JSONDecodeError, KeyError, TypeError, ValueError):
            continue
    return []



def _extract_html_layout_walk(soup: BeautifulSoup, base_url: str) -> dict[str, dict[str, Any]]:
    """HTML から url → {layout, walk_min, station_line, total_units} を抽出。mod-mergeBuilding と mod-listKks を処理。"""
    by_url: dict[str, dict[str, Any]] = {}

    def table_cell_value(vtable, header_text: str) -> str:
        if not vtable:
            return ""
        for tr in vtable.find_all("tr"):
            ths = tr.find_all("th")
            tds = tr.find_all("td")
            for i, th in enumerate(ths):
                if header_text in (th.get_text() or ""):
                    if i < len(tds):
                        return (tds[i].get_text() or "").strip()
                    break
        return ""

    # mod-mergeBuilding--sale: 1ブロック内に複数ユニット（tr.data-href / a[href*="/mansion/b-"]）
    for block in soup.select("div.mod-mergeBuilding--sale.cMansion"):
        building_spec = block.select_one("div.bukkenSpec table.verticalTable")
        building_traffic = ""
        building_floor_total: Optional[int] = None
        if building_spec:
            building_traffic = (table_cell_value(building_spec, "交通") or "").strip()
            building_floor_total = parse_floor_total((building_spec.get_text() or ""))
        if building_floor_total is None:
            building_floor_total = parse_floor_total((block.get_text() or ""))
        building_walk = parse_walk_min(building_traffic)
        building_station = re.sub(r"\s*徒歩[^\s]*", "", building_traffic).strip() or ""

        for tr in block.select("table.unitSummary tbody tr[data-href], table.unitSummary tbody tr.raSpecRow"):
            href = tr.get("data-href")
            if not href:
                a = tr.find("a", href=re.compile(r"/mansion/b-\d+/"))
                href = a.get("href") if a else None
            if not href:
                continue
            url = urljoin(base_url, href)
            vt = tr.select_one("td.info table.verticalTable")
            layout = table_cell_value(vt, "間取り")
            walk_min = building_walk
            station_line = building_station
            # 所在階: td.info 内の span（例: u-text-sm u-font-bold）で「○階」
            floor_position: Optional[int] = None
            for span in tr.select("td.info span"):
                t = (span.get_text() or "").strip()
                if t:
                    floor_position = parse_floor_position(t)
                    if floor_position is not None:
                        break
            if floor_position is None:
                floor_position = parse_floor_position((tr.get_text() or ""))
            # 同一 tr の次の memberDataRow の textFeatureComment で徒歩・駅名を上書き
            next_tr = tr.find_next_sibling("tr", class_=re.compile(r"memberDataRow|prg-memberDataRow"))
            total_units = None
            if next_tr:
                tc = next_tr.select_one("p.textFeatureComment")
                if tc:
                    t = (tc.get_text() or "").strip()
                    w = parse_walk_min(t)
                    if w is not None:
                        walk_min = w
                    # 「〇〇駅徒歩○分」のような部分だけ station_line に使う
                    station_m = re.search(r"[^\s/]+駅\s*徒歩\s*約?\s*\d+\s*分", t)
                    if station_m:
                        station_line = station_m.group(0)
                    total_units = parse_total_units_strict(t)
            ownership = table_cell_value(vt, "権利") or table_cell_value(vt, "権利形態") if vt else ""
            ownership = (parse_ownership(ownership) or parse_ownership(tr.get_text() or ""))
            mgmt_str = table_cell_value(vt, "管理費") if vt else ""
            repair_str = table_cell_value(vt, "修繕積立金") if vt else ""
            by_url[url] = {
                "layout": layout,
                "walk_min": walk_min,
                "station_line": station_line,
                "total_units": total_units,
                "floor_position": floor_position,
                "floor_total": building_floor_total,
                "ownership": ownership,
                "management_fee": parse_monthly_yen(mgmt_str) if mgmt_str else None,
                "repair_reserve_fund": parse_monthly_yen(repair_str) if repair_str else None,
            }

    # mod-listKks.mod-listKks-sale: 1カード1物件
    for bloc in soup.select("div.mod-listKks.mod-listKks-sale.cMansion"):
        a = bloc.find("a", class_=re.compile(r"prg-detailLink|detailLink"), href=True)
        if not a:
            continue
        url = urljoin(base_url, a.get("href", ""))
        vt = bloc.select_one("table.verticalTable")
        layout = table_cell_value(vt, "間取り") if vt else ""
        text_all = (bloc.get_text() or "")
        walk_min = parse_walk_min(text_all)
        station_line = ""
        tc = bloc.select_one("p.textFeatureComment")
        if tc:
            station_line = (tc.get_text() or "").strip()
        if not station_line and "駅" in text_all:
            m = re.search(r"[^\s]+駅[^\s]*", text_all)
            if m:
                station_line = m.group(0)
        total_units = parse_total_units_strict(text_all) if text_all else None
        # 所在階: span.bukkenRoom や リンク内の「○階」
        floor_position: Optional[int] = None
        room_span = bloc.select_one("span.bukkenRoom")
        if room_span:
            floor_position = parse_floor_position((room_span.get_text() or ""))
        if floor_position is None:
            floor_position = parse_floor_position(text_all)
        floor_total = parse_floor_total(text_all)
        ownership = table_cell_value(vt, "権利") or table_cell_value(vt, "権利形態") if vt else ""
        ownership = parse_ownership(ownership) or parse_ownership(text_all)
        mgmt_str = table_cell_value(vt, "管理費") if vt else ""
        repair_str = table_cell_value(vt, "修繕積立金") if vt else ""
        by_url[url] = {
            "layout": layout,
            "walk_min": walk_min,
            "station_line": station_line,
            "total_units": total_units,
            "floor_position": floor_position,
            "floor_total": floor_total,
            "ownership": ownership,
            "management_fee": parse_monthly_yen(mgmt_str) if mgmt_str else None,
            "repair_reserve_fund": parse_monthly_yen(repair_str) if repair_str else None,
        }

    return by_url


def _extract_card_listings(soup: BeautifulSoup, base_url: str) -> list[HomesListing]:
    """2026年リニューアル後のカード型一覧からパース。
    各物件はテーブル（価格/間取り/所在地/専有面積/交通 等）を含むブロック。
    """
    items: list[HomesListing] = []
    seen_urls: set[str] = set()

    # 物件詳細リンク /mansion/b-{id}/ を探す
    detail_links = soup.find_all("a", href=re.compile(r"/mansion/b-\d+/?$"))
    for link in detail_links:
        href = link.get("href", "")
        url = urljoin(base_url, href)
        if url in seen_urls:
            continue
        # リンクのテキストが「詳細を見る」等でない場合はスキップ
        # 物件ブロックを探す: リンクを含む最も近いコンテナ
        container = link
        for _ in range(15):
            container = container.parent
            if container is None or container.name in ("body", "html", "[document]"):
                container = None
                break
            text = container.get_text() or ""
            # 所在地と価格の両方を含むブロックを探す
            if "所在地" in text or ("万円" in text and ("m²" in text or "㎡" in text)):
                # テーブルが含まれるか、またはカード情報がある
                if container.find("table") or container.find(["dt", "th"]):
                    break
        if container is None:
            continue
        seen_urls.add(url)

        text = container.get_text(separator="\n")

        # 物件名: h2/h3/h4 または最初のリンクテキスト
        name = ""
        for tag in ("h2", "h3", "h4"):
            el = container.find(tag)
            if el:
                raw = (el.get_text(strip=True) or "").strip()
                cleaned = clean_listing_name(raw)
                if cleaned:
                    name = cleaned
                    break
        if not name:
            a = container.find("a", href=re.compile(r"/mansion/b-"))
            if a:
                t = (a.get_text(strip=True) or "").strip()
                if t and "詳細" not in t and "資料" not in t:
                    name = clean_listing_name(t)

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
            # dt/dd フォールバック
            dt = container.find(["dt", "th"], string=re.compile(re.escape(label)))
            if dt:
                sibling = dt.find_next_sibling(["dd", "td"])
                if sibling:
                    return (sibling.get_text(strip=True) or "").strip()
            return ""

        address = _table_value("所在地")
        station_line = _table_value("交通")
        layout = _table_value("間取り") or _table_value("間取")
        area_str = _table_value("専有面積") or _table_value("面積")
        price_str = _table_value("価格")
        built_str = _table_value("築年月") or _table_value("完成")

        price_man = parse_price(price_str) if price_str else None
        area_m2 = parse_area_m2(area_str) if area_str else None
        walk_min = parse_walk_min(station_line or text)
        built_year = parse_built_year(built_str or text)
        total_units = parse_total_units_strict(text)
        floor_total = parse_floor_total(text)
        floor_position = parse_floor_position(text)

        # テキストからの価格フォールバック
        if price_man is None:
            for line in text.split("\n"):
                line = line.strip()
                if "万円" in line and len(line) < 40:
                    price_man = parse_price(line)
                    if price_man is not None:
                        break

        # テキストからの面積フォールバック
        if area_m2 is None:
            area_m2 = parse_area_m2(text)

        if not name and not url:
            continue

        # 管理費・修繕積立金
        mgmt_str = _table_value("管理費")
        repair_str = _table_value("修繕積立金")
        management_fee = parse_monthly_yen(mgmt_str) if mgmt_str else None
        repair_reserve_fund = parse_monthly_yen(repair_str) if repair_str else None

        items.append(HomesListing(
            source="homes",
            url=url,
            name=name,
            price_man=price_man,
            address=address,
            station_line=station_line,
            walk_min=walk_min,
            area_m2=area_m2,
            layout=layout,
            built_str=built_str or (f"{built_year}年" if built_year else ""),
            built_year=built_year,
            total_units=total_units,
            floor_position=floor_position,
            floor_total=floor_total,
            management_fee=management_fee,
            repair_reserve_fund=repair_reserve_fund,
        ))
    return items


def parse_list_html(html: str, base_url: str = BASE_URL) -> list[HomesListing]:
    """HOME'S 一覧HTMLから物件リストをパース。JSON-LD を主とし、HTML から間取り・徒歩・路線を補完。
    2026年リニューアル後はカード型パーサーにフォールバック。"""
    soup = BeautifulSoup(html, "lxml")
    rows_ld = _parse_jsonld_itemlist(html)
    html_map = _extract_html_layout_walk(soup, base_url)

    items: list[HomesListing] = []
    for r in rows_ld:
        url = r.get("url") or ""
        extra = html_map.get(url) or {}
        layout = (extra.get("layout") or "").strip()
        walk_min = extra.get("walk_min")
        station_line = (extra.get("station_line") or "").strip()
        total_units = extra.get("total_units")
        floor_position = extra.get("floor_position")
        floor_total = extra.get("floor_total")
        items.append(HomesListing(
            source="homes",
            url=url,
            name=clean_listing_name(r.get("name") or ""),
            price_man=r.get("price_man"),
            address=r.get("address") or "",
            station_line=station_line,
            walk_min=walk_min,
            area_m2=r.get("area_m2"),
            layout=layout,
            built_str=r.get("built_str") or "",
            built_year=r.get("built_year"),
            total_units=total_units,
            floor_position=floor_position,
            floor_total=floor_total,
            ownership=extra.get("ownership") if isinstance(extra.get("ownership"), str) else None,
            management_fee=extra.get("management_fee"),
            repair_reserve_fund=extra.get("repair_reserve_fund"),
        ))

    # フォールバック: JSON-LD + 旧HTMLセレクタで0件の場合、カード型パーサーを試行
    if not items:
        items = _extract_card_listings(soup, base_url)

    return items


def apply_conditions(listings: list[HomesListing]) -> list[HomesListing]:
    """価格・専有・間取り・築年・徒歩・地域（東京23区）・路線・総戸数・駅乗降客数で条件ドキュメントに合わせてフィルタ。"""
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


def scrape_homes(max_pages: Optional[int] = 2, apply_filter: bool = True) -> Iterator[HomesListing]:
    """HOME'S 東京23区中古マンション一覧を取得。max_pages=0 のときは結果がなくなるまで全ページ取得。"""
    session = create_session()
    limit = max_pages if max_pages and max_pages > 0 else HOMES_MAX_PAGES_SAFETY
    page = 1
    total_parsed = 0
    total_passed = 0
    pages_since_last_pass = 0  # 最後の通過からの連続ページ数（早期打ち切り用）
    start_time = time.monotonic()
    while page <= limit:
        # タイムリミットチェック（WAF 遅延でパイプライン全体がタイムアウトするのを防止）
        elapsed = time.monotonic() - start_time
        if elapsed > HOMES_SCRAPE_TIMEOUT_SEC:
            print(f"HOME'S: タイムリミット到達（{int(elapsed)}秒, {page - 1}ページ処理済, 通過: {total_passed}件）", file=sys.stderr)
            break
        url = LIST_URL_FIRST if page == 1 else LIST_URL_PAGE.format(page=page)
        try:
            html = fetch_list_page(session, url)
        except Exception as e:
            print(f"HOME'S: ページ{page}でエラー（WAF/ネットワーク）: {e}", file=sys.stderr)
            break
        rows = parse_list_html(html)
        if not rows:
            print(f"HOME'S: ページ{page}で0件パース。一覧のHTML構造が変わった可能性があります。", file=sys.stderr)
            break
        total_parsed += len(rows)
        passed = 0
        for row in rows:
            if apply_filter:
                filtered = apply_conditions([row])
                if filtered:
                    yield filtered[0]
                    passed += 1
                    print(f"  ✓ {filtered[0].name} ({filtered[0].price_man}万)", file=sys.stderr)
            else:
                yield row
                passed += 1
        total_passed += passed
        # 早期打ち切り判定: 連続 N ページで新規通過0件なら中断
        if passed > 0:
            pages_since_last_pass = 0
        else:
            pages_since_last_pass += 1
        if pages_since_last_pass >= HOMES_EARLY_EXIT_PAGES:
            print(f"HOME'S: 早期打ち切り（{pages_since_last_pass}ページ連続で通過0件, 累計通過: {total_passed}件）", file=sys.stderr)
            break
        # 進捗: 10ページごとにサマリー
        if page % 10 == 0:
            print(f"HOME'S: ...{page}ページ処理済 (通過: {total_passed}件)", file=sys.stderr)
        page += 1
    if total_parsed > 0:
        print(f"HOME'S: 完了 — {total_parsed}件パース, {total_passed}件通過", file=sys.stderr)