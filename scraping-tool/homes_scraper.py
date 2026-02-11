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
    BUILT_YEAR_MIN,
    WALK_MIN_MAX,
    TOTAL_UNITS_MIN,
    STATION_PASSENGERS_MIN,
    ALLOWED_LINE_KEYWORDS,
    HOMES_REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
    REQUEST_RETRIES,
    USER_AGENT,
    TOKYO_23_WARDS,
)

BASE_URL = "https://www.homes.co.jp"

# 東京23区・中古マンション一覧（全ページ /tokyo/23ku/list/?page=N）
# ※2026年2月確認: /tokyo/23ku/ はナビゲーションページに変更されたため /list/ パスを使用
LIST_URL_FIRST = "https://www.homes.co.jp/mansion/chuko/tokyo/23ku/list/"
LIST_URL_PAGE = "https://www.homes.co.jp/mansion/chuko/tokyo/23ku/list/?page={page}"
# 全ページ取得時の安全上限（無限ループ防止）
HOMES_MAX_PAGES_SAFETY = 100


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

    def to_dict(self):
        return asdict(self)


def _session() -> requests.Session:
    s = requests.Session()
    s.headers["User-Agent"] = USER_AGENT
    s.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    s.headers["Accept-Language"] = "ja,en;q=0.9"
    return s


def _parse_price(s: str) -> Optional[int]:
    if not s:
        return None
    s = s.replace(",", "").strip()
    if "億" in s:
        m = re.search(r"([0-9.]+)億([0-9.]*)\s*万?", s)
        if m:
            return int(float(m.group(1)) * 10000 + float(m.group(2) or 0))
    m = re.search(r"([0-9.,]+)\s*万", s)
    return int(float(m.group(1).replace(",", ""))) if m else None


def _parse_area_m2(s: str) -> Optional[float]:
    if not s:
        return None
    m = re.search(r"([0-9.]+)\s*(?:m2|㎡|m\s*2)", s, re.I)
    return float(m.group(1)) if m else None


def _parse_walk_min(s: str) -> Optional[int]:
    if not s:
        return None
    m = re.search(r"徒歩\s*約?\s*([0-9]+)\s*分", s)
    return int(m.group(1)) if m else None


def _parse_built_year(s: str) -> Optional[int]:
    if not s:
        return None
    m = re.search(r"([0-9]{4})\s*年", s)
    return int(m.group(1)) if m else None


def _layout_ok(layout: str) -> bool:
    if not layout:
        return False
    layout = layout.strip()
    return any(
        layout.startswith(p) or layout.replace("K", "DK").startswith(p)
        for p in ("2", "3")
    ) and ("LDK" in layout or "DK" in layout or "K" in layout)


def _is_waf_challenge(html: str) -> bool:
    """AWS WAF のボット検知チャレンジページかどうかを判定。"""
    if len(html) < 5000 and "awsWafCookieDomainList" in html:
        return True
    if len(html) < 5000 and "gokuProps" in html:
        return True
    return False


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
            if _is_waf_challenge(html):
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


def _parse_total_units(text: str) -> Optional[int]:
    """テキストから総戸数を抽出。例: 総戸数143戸 → 143。"""
    if not text:
        return None
    m = re.search(r"総戸数\s*(\d+)\s*戸", text)
    return int(m.group(1)) if m else None


def _parse_floor_position(text: str) -> Optional[int]:
    """「5階」「13階」などから所在階を返す（階建は除く）。"""
    if not text:
        return None
    m = re.search(r"(\d+)\s*階(?!建)", text)
    return int(m.group(1)) if m else None


def _parse_floor_total(text: str) -> Optional[int]:
    """「10階建」「6階建て」などから建物階数を返す。"""
    if not text:
        return None
    m = re.search(r"(\d+)\s*階\s*建(?:て)?", text)
    return int(m.group(1)) if m else None


def _parse_ownership(text: str) -> Optional[str]:
    """テキストから権利形態（所有権・借地権・底地権等）を抽出。"""
    if not text or not text.strip():
        return None
    m = re.search(r"(所有権|借地権|底地権|普通借地権|定期借地権)", (text or "").strip())
    return m.group(1).strip() if m else None


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
            building_floor_total = _parse_floor_total((building_spec.get_text() or ""))
        if building_floor_total is None:
            building_floor_total = _parse_floor_total((block.get_text() or ""))
        building_walk = _parse_walk_min(building_traffic)
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
                    floor_position = _parse_floor_position(t)
                    if floor_position is not None:
                        break
            if floor_position is None:
                floor_position = _parse_floor_position((tr.get_text() or ""))
            # 同一 tr の次の memberDataRow の textFeatureComment で徒歩・駅名を上書き
            next_tr = tr.find_next_sibling("tr", class_=re.compile(r"memberDataRow|prg-memberDataRow"))
            total_units = None
            if next_tr:
                tc = next_tr.select_one("p.textFeatureComment")
                if tc:
                    t = (tc.get_text() or "").strip()
                    w = _parse_walk_min(t)
                    if w is not None:
                        walk_min = w
                    # 「〇〇駅徒歩○分」のような部分だけ station_line に使う
                    station_m = re.search(r"[^\s/]+駅\s*徒歩\s*約?\s*\d+\s*分", t)
                    if station_m:
                        station_line = station_m.group(0)
                    total_units = _parse_total_units(t)
            ownership = table_cell_value(vt, "権利") or table_cell_value(vt, "権利形態") if vt else ""
            ownership = (_parse_ownership(ownership) or _parse_ownership(tr.get_text() or ""))
            by_url[url] = {
                "layout": layout,
                "walk_min": walk_min,
                "station_line": station_line,
                "total_units": total_units,
                "floor_position": floor_position,
                "floor_total": building_floor_total,
                "ownership": ownership,
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
        walk_min = _parse_walk_min(text_all)
        station_line = ""
        tc = bloc.select_one("p.textFeatureComment")
        if tc:
            station_line = (tc.get_text() or "").strip()
        if not station_line and "駅" in text_all:
            m = re.search(r"[^\s]+駅[^\s]*", text_all)
            if m:
                station_line = m.group(0)
        total_units = _parse_total_units(text_all) if text_all else None
        # 所在階: span.bukkenRoom や リンク内の「○階」
        floor_position: Optional[int] = None
        room_span = bloc.select_one("span.bukkenRoom")
        if room_span:
            floor_position = _parse_floor_position((room_span.get_text() or ""))
        if floor_position is None:
            floor_position = _parse_floor_position(text_all)
        floor_total = _parse_floor_total(text_all)
        ownership = table_cell_value(vt, "権利") or table_cell_value(vt, "権利形態") if vt else ""
        ownership = _parse_ownership(ownership) or _parse_ownership(text_all)
        by_url[url] = {
            "layout": layout,
            "walk_min": walk_min,
            "station_line": station_line,
            "total_units": total_units,
            "floor_position": floor_position,
            "floor_total": floor_total,
            "ownership": ownership,
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
                name = (el.get_text(strip=True) or "").strip()
                if name:
                    break
        if not name:
            a = container.find("a", href=re.compile(r"/mansion/b-"))
            if a:
                t = (a.get_text(strip=True) or "").strip()
                if t and "詳細" not in t and "資料" not in t:
                    name = t

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

        price_man = _parse_price(price_str) if price_str else None
        area_m2 = _parse_area_m2(area_str) if area_str else None
        walk_min = _parse_walk_min(station_line or text)
        built_year = _parse_built_year(built_str or text)
        total_units = _parse_total_units(text)
        floor_total = _parse_floor_total(text)
        floor_position = _parse_floor_position(text)

        # テキストからの価格フォールバック
        if price_man is None:
            for line in text.split("\n"):
                line = line.strip()
                if "万円" in line and len(line) < 40:
                    price_man = _parse_price(line)
                    if price_man is not None:
                        break

        # テキストからの面積フォールバック
        if area_m2 is None:
            area_m2 = _parse_area_m2(text)

        if not name and not url:
            continue

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
            name=r.get("name") or "",
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
        ))

    # フォールバック: JSON-LD + 旧HTMLセレクタで0件の場合、カード型パーサーを試行
    if not items:
        items = _extract_card_listings(soup, base_url)

    return items


def _address_in_tokyo_23(address: str) -> bool:
    """住所が東京23区のいずれかを含むか。"""
    if not (address and address.strip()):
        return False
    return any(ward in address for ward in TOKYO_23_WARDS)


def _line_ok(station_line: str) -> bool:
    """路線限定時、最寄り路線がALLOWED_LINE_KEYWORDSのいずれかを含むか。空のときは全通過。"""
    if not ALLOWED_LINE_KEYWORDS:
        return True
    line = (station_line or "").strip()
    if not line:
        return False
    return any(kw in line for kw in ALLOWED_LINE_KEYWORDS)


def _load_station_passengers() -> dict[str, int]:
    """data/station_passengers.json から 駅名 → 乗降客数 を読み込む。"""
    path = Path(__file__).resolve().parent / "data" / "station_passengers.json"
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def _station_name_from_line(station_line: str) -> str:
    """station_line から駅名を抽出。「」内があればそれ、なければ『〇〇駅』の部分。"""
    if not (station_line and station_line.strip()):
        return ""
    m = re.search(r"[「『]([^」』]+)[」』]", station_line)
    if m:
        return m.group(1).strip()
    m = re.search(r"([^\s]+駅)", station_line)
    if m:
        return m.group(1).strip()
    return (station_line.strip()[:30] or "").strip()


def _station_passengers_ok(station_line: str, passengers_map: dict[str, int]) -> bool:
    """駅乗降客数フィルタ。STATION_PASSENGERS_MIN > 0 かつデータがあるときのみチェック。"""
    if STATION_PASSENGERS_MIN <= 0 or not passengers_map:
        return True
    name = _station_name_from_line(station_line or "")
    if not name:
        return True
    passengers = passengers_map.get(name) or passengers_map.get(name.replace("駅", "")) or passengers_map.get(name + "駅")
    if passengers is None:
        return True
    return passengers >= STATION_PASSENGERS_MIN


def apply_conditions(listings: list[HomesListing]) -> list[HomesListing]:
    """価格・専有・間取り・築年・徒歩・地域（東京23区）・路線・総戸数・駅乗降客数で条件ドキュメントに合わせてフィルタ。"""
    passengers_map = _load_station_passengers()
    out = []
    for r in listings:
        if not _address_in_tokyo_23(r.address):
            continue
        if not _line_ok(r.station_line):
            continue
        if not _station_passengers_ok(r.station_line, passengers_map):
            continue
        if r.price_man is not None and (r.price_man < PRICE_MIN_MAN or r.price_man > PRICE_MAX_MAN):
            continue
        if r.area_m2 is not None and (r.area_m2 < AREA_MIN_M2 or (AREA_MAX_M2 is not None and r.area_m2 > AREA_MAX_M2)):
            continue
        if not _layout_ok(r.layout):
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
    session = _session()
    limit = max_pages if max_pages and max_pages > 0 else HOMES_MAX_PAGES_SAFETY
    page = 1
    while page <= limit:
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
            print(f"HOME'S: ページ{page}で{len(rows)}件パースしたが条件通過0件（価格・地域・間取り等で除外）。", file=sys.stderr)
        page += 1