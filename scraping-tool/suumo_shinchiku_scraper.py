"""
SUUMO 新築マンション一覧のスクレイピング（私的利用・軽負荷前提）。
利用規約: terms-check.md を参照。

一覧URL: https://suumo.jp/jj/bukken/ichiran/JJ011FC001/?ar=030&bs=010&ta=13
ページング: &page=N

新築は棟単位の情報（価格帯・間取り幅・面積幅・引渡時期）。
中古と同じ config.py のフィルタ条件を適用するが、
新築固有のロジック（価格未定の許容、間取り幅マッチ、築年フィルタ不要など）に対応。
"""

import re
import sys
import time
from dataclasses import dataclass, asdict, field
from typing import Iterator, Optional
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

from config import (
    PRICE_MIN_MAN,
    PRICE_MAX_MAN,
    AREA_MIN_M2,
    AREA_MAX_M2,
    WALK_MIN_MAX,
    TOTAL_UNITS_MIN,
    STATION_PASSENGERS_MIN,
    ALLOWED_LINE_KEYWORDS,
    REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
    REQUEST_RETRIES,
    USER_AGENT,
    SUUMO_23_WARD_ROMAN,
)
from parse_utils import (
    parse_price_range,
    parse_area_range,
    parse_walk_min_best,
    parse_total_units,
    parse_floor_total_lenient,
    parse_ownership_from_text,
    layout_range_ok,
)
from report_utils import clean_listing_name
from scraper_common import (
    create_session,
    load_station_passengers,
    station_passengers_ok,
    line_ok,
    is_tokyo_23_by_address,
)

BASE_URL = "https://suumo.jp"

# 東京都 新築分譲マンション一覧（bs=010: 新築分譲マンション, ta=13: 東京都）
LIST_URL_BASE = "https://suumo.jp/jj/bukken/ichiran/JJ011FC001/?ar=030&bs=010&ta=13"
# 全ページ取得時の安全上限
SHINCHIKU_MAX_PAGES_SAFETY = 100


@dataclass
class SuumoShinchikuListing:
    """SUUMO 新築マンション一覧から得た1件分（棟単位）。"""

    source: str = "suumo"
    property_type: str = "shinchiku"
    url: str = ""
    name: str = ""
    price_man: Optional[int] = None          # 価格帯下限（万円）、価格未定なら None
    price_max_man: Optional[int] = None      # 価格帯上限（万円）
    address: str = ""
    station_line: str = ""
    walk_min: Optional[int] = None
    area_m2: Optional[float] = None          # 面積幅下限（㎡）
    area_max_m2: Optional[float] = None      # 面積幅上限（㎡）
    layout: str = ""                         # "2LDK～4LDK" 等（幅表記）
    delivery_date: str = ""                  # 引渡時期（例: "2027年9月上旬予定"）
    total_units: Optional[int] = None
    floor_total: Optional[int] = None
    list_ward_roman: Optional[str] = None

    # 中古との互換性用（新築では基本 None / 空）
    built_str: str = ""
    built_year: Optional[int] = None
    floor_position: Optional[int] = None
    floor_structure: Optional[str] = None
    ownership: Optional[str] = None

    def to_dict(self):
        return asdict(self)


# ---------- パース補助関数（SUUMO 新築専用） ----------

def _extract_ward_from_url(url: str) -> Optional[str]:
    """detail URL /ms/shinchiku/tokyo/sc_{ward}/nc_{id}/ から ward を抽出。"""
    m = re.search(r"/sc_([a-z]+)/", url)
    return m.group(1) if m else None


# ---------- ページ取得 ----------

def fetch_list_page(session: requests.Session, page: int = 1) -> str:
    """一覧ページのHTMLを取得。"""
    url = LIST_URL_BASE
    if page > 1:
        url = f"{url}&page={page}"
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            # 429 Too Many Requests — レートリミット対策
            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                print(f"  429 Rate Limited, waiting {retry_after}s (attempt {attempt + 1}/{REQUEST_RETRIES})", file=sys.stderr)
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
            else:
                raise last_error
    if last_error is not None:
        raise last_error
    raise RuntimeError(f"全 {REQUEST_RETRIES} 回のリトライが失敗しました (429 Rate Limited)")


# ---------- HTMLパース ----------

def parse_list_html(html: str) -> list[SuumoShinchikuListing]:
    """新築マンション一覧HTMLから物件リストをパース。

    SUUMO 新築ページの構造:
    - 各物件ブロックに h2 で物件名
    - DT/DD で「所在地」「交通」「引渡時期」
    - 価格行（例: "4900万円台～8300万円台／予定"）
    - 間取り/面積行（例: "2LDK～4LDK / 60.71m2～85.42m2"）
    - 詳細リンク /ms/shinchiku/tokyo/sc_{ward}/nc_{id}/
    """
    soup = BeautifulSoup(html, "lxml")
    items: list[SuumoShinchikuListing] = []

    # 物件ブロックを探す: 詳細リンク（/ms/shinchiku/tokyo/sc_*）を含むセクション
    detail_links = soup.find_all("a", href=re.compile(r"/ms/shinchiku/tokyo/sc_[a-z]+/nc_\d+/$"))
    # 各 detail_link の周辺ブロックから物件情報を抽出
    seen_urls: set[str] = set()

    for link in detail_links:
        detail_url = urljoin(BASE_URL, link.get("href", ""))
        if detail_url in seen_urls:
            continue
        seen_urls.add(detail_url)

        # 物件ブロックを探す: detail_link を含む最も近い大きなコンテナ
        container = _find_listing_container(link)
        if not container:
            continue

        listing = _parse_listing_block(container, detail_url)
        if listing:
            items.append(listing)

    return items


def _find_listing_container(link_element) -> Optional[object]:
    """詳細リンクを含む物件ブロック（コンテナ）を上方向に探索。"""
    # h2 を含むレベルまで遡る
    el = link_element
    for _ in range(15):  # 安全上限
        el = el.parent
        if el is None or el.name in ("body", "html", "[document]"):
            return None
        # コンテナの目安: h2 を含み、所在地・交通などの情報がある
        if el.find("h2") and ("所在地" in (el.get_text() or "")):
            return el
    return None


def _parse_listing_block(container, detail_url: str) -> Optional[SuumoShinchikuListing]:
    """1つの物件ブロックからデータを抽出。"""
    try:
        text = container.get_text(separator="\n")

        # 物件名: h2 から
        h2 = container.find("h2")
        raw_name = (h2.get_text(strip=True) or "").strip() if h2 else ""
        name = clean_listing_name(raw_name) or raw_name

        # DT/DD パース
        def get_dd(label: str) -> str:
            dt = container.find("dt", string=re.compile(re.escape(label)))
            if dt:
                dd = dt.find_next_sibling("dd")
                if dd:
                    return (dd.get_text(strip=True) or "").strip()
            # テキストフォールバック
            m = re.search(rf"{re.escape(label)}\s*\n?\s*([^\n]+)", text)
            return (m.group(1).strip() if m else "").strip()

        address = get_dd("所在地")
        station_line = get_dd("交通")
        delivery_date = get_dd("引渡時期")

        walk_min = parse_walk_min_best(station_line)

        # 価格: コンテナ内のテキストから価格パターンを探す
        price_man, price_max_man = _extract_price_from_text(text)

        # 間取り / 面積: "2LDK～4LDK / 60.71m2～85.42m2" パターン
        layout, area_m2, area_max_m2 = _extract_layout_area(text)

        # 総戸数: 説明文から
        total_units = parse_total_units(text)
        # 階数: 説明文から
        floor_total = parse_floor_total_lenient(text)

        # 権利形態: DT/DD または テキストから
        ownership = get_dd("権利形態") or get_dd("敷地の権利形態") or get_dd("権利")
        if not ownership:
            ownership = parse_ownership_from_text(text)

        # ward: detail URL から
        ward = _extract_ward_from_url(detail_url)

        return SuumoShinchikuListing(
            url=detail_url,
            name=name or "（不明）",
            price_man=price_man,
            price_max_man=price_max_man,
            address=address,
            station_line=station_line,
            walk_min=walk_min,
            area_m2=area_m2,
            area_max_m2=area_max_m2,
            layout=layout,
            delivery_date=delivery_date,
            total_units=total_units,
            floor_total=floor_total,
            list_ward_roman=ward,
            ownership=ownership or None,
        )
    except Exception:
        return None


def _extract_price_from_text(text: str) -> tuple[Optional[int], Optional[int]]:
    """テキストから価格行を抽出してパース。
    複数の価格行がある場合（例: ザ タワー ノース / ザ タワー サウス）、最初のものを採用。
    """
    lines = text.split("\n")
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # 価格未定
        if re.match(r"^価格未定", line):
            return (None, None)
        # 「○万円台～○万円台」or「○万円～○万円」パターン
        if re.search(r"万円", line) and not re.search(r"タイプ", line):
            # 間取りタイプ行は除外
            if re.search(r"[LDK].*m2", line):
                continue
            result = parse_price_range(line)
            if result != (None, None) or "価格未定" in line:
                return result
    return (None, None)


def _extract_layout_area(text: str) -> tuple[str, Optional[float], Optional[float]]:
    """テキストから間取り/面積行を抽出。
    例: "2LDK～4LDK / 60.71m2～85.42m2"
    """
    lines = text.split("\n")
    for line in lines:
        line = line.strip()
        # 間取りと面積が同一行にあるパターン
        if re.search(r"[0-9LDKS（納戸）R+・～〜]+\s*/\s*[0-9.]+\s*(?:m2|㎡)", line, re.I):
            parts = line.split("/", 1)
            layout_part = parts[0].strip() if len(parts) > 0 else ""
            area_part = parts[1].strip() if len(parts) > 1 else ""
            area_min, area_max = parse_area_range(area_part)
            return (layout_part, area_min, area_max)
    # フォールバック: 間取りだけ or 面積だけ
    layout = ""
    area_min = None
    area_max = None
    for line in lines:
        line = line.strip()
        if not layout and re.search(r"[0-9]+[LDKS]", line) and "タイプ" not in line:
            # 行全体ではなく間取りパターンだけ抽出（マーケティングテキスト混入を防止）
            m = re.search(
                r"(\d[LDKS（納戸）R+・]+(?:\s*[～〜]\s*\d[LDKS（納戸）R+・]+)?)",
                line,
            )
            layout = m.group(1).strip() if m else line[:40]
        if area_min is None and re.search(r"[0-9.]+\s*(?:m2|㎡)", line, re.I):
            area_min, area_max = parse_area_range(line)
    return (layout, area_min, area_max)


# ---------- フィルタ ----------

def _is_tokyo_23(address: str, list_ward_roman: Optional[str] = None) -> bool:
    """東京23区の物件かどうか。SUUMO の list_ward_roman または住所で判定。"""
    if list_ward_roman and list_ward_roman in SUUMO_23_WARD_ROMAN:
        return True
    return is_tokyo_23_by_address(address)


def apply_conditions(listings: list[SuumoShinchikuListing]) -> list[SuumoShinchikuListing]:
    """新築マンション用のフィルタ。中古と同じ条件を適用するが新築固有の調整あり。

    - 価格: 価格未定は通過。帯の場合はレンジが重なれば通過。
    - 面積: 帯の上限が AREA_MIN_M2 以上なら通過。
    - 間取り: 幅に 2 or 3 が含まれれば通過。
    - 築年: 新築なのでスキップ。
    - 徒歩: 中古と同じ。
    - 地域: 23区限定。
    - 路線: 中古と同じ。
    """
    passengers_map = load_station_passengers()
    out = []
    for r in listings:
        if not _is_tokyo_23(r.address, r.list_ward_roman):
            continue
        if not line_ok(r.station_line):
            continue
        if not station_passengers_ok(r.station_line, passengers_map):
            continue

        # 価格: 価格未定は通過。帯の場合はレンジ重なりチェック。
        if r.price_man is not None:
            price_hi = r.price_max_man or r.price_man
            # レンジが重なるか: [price_man, price_hi] ∩ [PRICE_MIN_MAN, PRICE_MAX_MAN]
            if price_hi < PRICE_MIN_MAN or r.price_man > PRICE_MAX_MAN:
                continue

        # 面積: 帯の上限が条件以上か。
        area_hi = r.area_max_m2 or r.area_m2
        if area_hi is not None and area_hi < AREA_MIN_M2:
            continue
        if AREA_MAX_M2 is not None and r.area_m2 is not None and r.area_m2 > AREA_MAX_M2:
            continue

        # 間取り
        if not layout_range_ok(r.layout):
            continue

        # 徒歩
        if r.walk_min is not None and r.walk_min > WALK_MIN_MAX:
            continue

        # 総戸数
        if r.total_units is not None and r.total_units < TOTAL_UNITS_MIN:
            continue

        out.append(r)
    return out


# ---------- メインエントリ ----------

def scrape_suumo_shinchiku(max_pages: Optional[int] = 0, apply_filter: bool = True) -> Iterator[SuumoShinchikuListing]:
    """SUUMO 新築マンション一覧を取得。max_pages=0 のときは全ページ取得。"""
    session = create_session()
    seen_urls: set[str] = set()
    limit = max_pages if max_pages and max_pages > 0 else SHINCHIKU_MAX_PAGES_SAFETY
    page = 1
    total_parsed = 0
    total_passed = 0
    while page <= limit:
        try:
            html = fetch_list_page(session, page)
        except requests.exceptions.HTTPError as e:
            if e.response is not None and 500 <= e.response.status_code < 600:
                print(f"SUUMO 新築: ページ{page} で {e.response.status_code} エラーのためスキップ", file=sys.stderr)
                page += 1
                continue
            raise
        rows = parse_list_html(html)
        if not rows:
            break
        total_parsed += len(rows)
        passed = 0
        for row in rows:
            if row.url and row.url not in seen_urls:
                seen_urls.add(row.url)
                if apply_filter:
                    filtered = apply_conditions([row])
                    if filtered:
                        yield filtered[0]
                        passed += 1
                        _price = f"{filtered[0].price_man}万" if filtered[0].price_man else "価格未定"
                        print(f"  ✓ {filtered[0].name} ({_price})", file=sys.stderr)
                else:
                    yield row
                    passed += 1
        total_passed += passed
        # 進捗: 10ページごとにサマリー
        if page % 10 == 0:
            print(f"SUUMO 新築: ...{page}ページ処理済 (通過: {total_passed}件)", file=sys.stderr)
        page += 1
    if total_parsed > 0:
        print(f"SUUMO 新築: 完了 — {total_parsed}件パース, {total_passed}件通過", file=sys.stderr)
