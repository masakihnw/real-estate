"""
SUUMO 中古マンション一覧のスクレイピング（私的利用・軽負荷前提）。
利用規約: terms-check.md を参照。駅徒歩5分以内などの条件付きURLから取得し、
ローカルで価格・専有・間取り・築年でフィルタする。
"""

import json
import re
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterator, Optional
from urllib.parse import urljoin, urlparse

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
    REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
    REQUEST_RETRIES,
    USER_AGENT,
    TOKYO_23_WARDS,
    NON_TOKYO_23_URL_PATHS,
)

BASE_URL = "https://suumo.jp"

# 23区の絞り方: /ms/chuko/tokyo/sc_区のローマ字/ で各区を同様に取得（全23区）
# 千代田・中央・港・新宿・文京・渋谷｜台東・墨田・江東・荒川・足立・葛飾・江戸川｜品川・目黒・大田・世田谷｜中野・杉並・練馬｜豊島・北・板橋
SUUMO_23_WARD_ROMAN = (
    "chiyoda", "chuo", "minato", "shinjuku", "bunkyo", "shibuya",
    "taito", "sumida", "koto", "arakawa", "adachi", "katsushika", "edogawa",
    "shinagawa", "meguro", "ota", "setagaya",
    "nakano", "suginami", "nerima",
    "toshima", "kita", "itabashi",
)
assert len(SUUMO_23_WARD_ROMAN) == 23, "23区のローマ字コードは23個"

# 23区ごと一覧: /ms/chuko/tokyo/sc_XXX/ 。2ページ目以降は ?page=N
LIST_URL_WARD_ROMAN = "https://suumo.jp/ms/chuko/tokyo/sc_{ward}/"
# 東京都全体一覧（従来・参考）: 多摩地域が先に並ぶため23区物件は後ろのページになりがち
LIST_URL_TEMPLATE = (
    "https://suumo.jp/jj/bukken/ichiran/JJ010FJ001/"
    "?ar=030&bs=011&ta=13&jspIdFlg=patternShikugun&kb=1&kt=500&mb=0&mt=9999999"
)


@dataclass
class SuumoListing:
    """SUUMO 一覧から得た1件分の項目（条件フィルタ前）"""

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
    total_units: Optional[int] = None  # 総戸数（詳細ページキャッシュから取得）
    floor_position: Optional[int] = None   # 所在階（何階）
    floor_total: Optional[int] = None     # 建物階数（何階建て）
    ownership: Optional[str] = None       # 権利形態（所有権・借地権・底地権等。一覧の「権利形態」から取得）
    list_ward_roman: Optional[str] = None  # 一覧取得元の区（sc_itabashi 等）。住所に区名が無くても23区判定に利用

    def to_dict(self):
        return asdict(self)


def _session() -> requests.Session:
    s = requests.Session()
    s.headers["User-Agent"] = USER_AGENT
    s.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    s.headers["Accept-Language"] = "ja,en;q=0.9"
    return s


def _parse_price(s: str) -> Optional[int]:
    """「1080万円」「1億4360万円」などから万円単位の数値を返す。"""
    if not s:
        return None
    s = s.replace(",", "").strip()
    if "億" in s:
        m = re.search(r"([0-9.]+)億([0-9.]*)\s*万?", s)
        if m:
            oku = float(m.group(1))
            man = float(m.group(2) or 0)
            return int(oku * 10000 + man)
    m = re.search(r"([0-9.,]+)\s*万", s)
    if m:
        return int(float(m.group(1).replace(",", "")))
    return None


def _parse_area_m2(s: str) -> Optional[float]:
    """「48.93m2」「48.93㎡」「48.93m2（14.80坪）」などから数値を返す。"""
    if not s:
        return None
    m = re.search(r"([0-9.]+)\s*m2|㎡|m\s*2", s, re.I)
    if m:
        return float(m.group(1))
    return None


def _parse_walk_min(s: str) -> Optional[int]:
    """「徒歩4分」「徒歩約3分」などから分を返す。"""
    if not s:
        return None
    m = re.search(r"徒歩\s*約?\s*([0-9]+)\s*分", s)
    if m:
        return int(m.group(1))
    return None


def _parse_built_year(s: str) -> Optional[int]:
    """「1976年3月」「2020年6月」などから年を返す。"""
    if not s:
        return None
    m = re.search(r"([0-9]{4})\s*年", s)
    if m:
        return int(m.group(1))
    return None


def _parse_floor_position(s: str) -> Optional[int]:
    """「5階」「13階」などから所在階を返す。"""
    if not s:
        return None
    m = re.search(r"(\d+)\s*階(?!建)", s)
    return int(m.group(1)) if m else None


def _parse_floor_total(s: str) -> Optional[int]:
    """「10階建」「6階建て」などから建物階数を返す。"""
    if not s:
        return None
    m = re.search(r"(\d+)\s*階\s*建(?:て)?", s)
    return int(m.group(1)) if m else None


def _layout_ok(layout: str) -> bool:
    """2LDK〜3LDK 系か（2DK/3DK 含む）。"""
    if not layout:
        return False
    layout = layout.strip()
    return any(
        layout.startswith(p) or layout.replace("K", "DK").startswith(p)
        for p in ("2", "3")
    ) and ("LDK" in layout or "DK" in layout or "K" in layout)


def fetch_list_page(
    session: requests.Session,
    page: int = 1,
    ward_roman: Optional[str] = None,
) -> str:
    """一覧ページのHTMLを取得。ward_roman 指定時は /ms/chuko/tokyo/sc_XXX/ を使用。"""
    if ward_roman is not None:
        url = LIST_URL_WARD_ROMAN.format(ward=ward_roman)
        if page > 1:
            url = f"{url}?page={page}"
    else:
        url = LIST_URL_TEMPLATE
        if page > 1:
            url = f"{url}&pn={page}"
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
        except requests.exceptions.HTTPError as e:
            # 502/503 は一時的なサーバーエラーのためリトライ
            if e.response is not None and e.response.status_code in (502, 503) and attempt < REQUEST_RETRIES - 1:
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
    if last_error:
        raise last_error


def parse_list_html(html: str, base_url: str = BASE_URL) -> list[SuumoListing]:
    """一覧HTMLから物件リストをパース。"""
    soup = BeautifulSoup(html, "lxml")
    items: list[SuumoListing] = []

    # 中古マンション一覧: div.property_unit-content が1物件ずつ
    for bloc in soup.select("div.property_unit-content"):
        row = _parse_suumo_unit(bloc, base_url)
        if row and row.price_man is not None:
            items.append(row)

    # フォールバック: cassetteitem 系
    if not items:
        for cassette in soup.find_all("div", class_=re.compile(r"cassetteitem")):
            row = _parse_cassette(cassette, base_url)
            if row:
                items.append(row)

    if not items:
        items = _parse_fallback(soup, base_url)

    return items


def _parse_suumo_unit(bloc, base_url: str) -> Optional[SuumoListing]:
    """div.property_unit-content から1件分をパース。"""
    try:
        # ラベルと値を dt/dd または dottable で取得
        def get_val(label: str) -> str:
            dt = bloc.find("dt", string=re.compile(re.escape(label)))
            if dt:
                dd = dt.find_next_sibling("dd")
                if dd:
                    return (dd.get_text(strip=True) or "").strip()
            # テキストで「ラベル \n 値」を探す
            txt = bloc.get_text()
            m = re.search(rf"{re.escape(label)}\s*[\s\n]*([^\n]+)", txt)
            return (m.group(1).strip() if m else "").strip()
        name = get_val("物件名") or "（不明）"
        price_man = _parse_price(get_val("販売価格"))
        address = get_val("所在地")
        station_line = get_val("沿線・駅")
        walk_min = _parse_walk_min(station_line)
        area_m2 = _parse_area_m2(get_val("専有面積"))
        layout = get_val("間取り")
        built_str = get_val("築年月")
        built_year = _parse_built_year(built_str)

        # 詳細URL: 同じブロック内の資料請求 or 物件リンク
        a = bloc.find("a", href=re.compile(r"/jj/bukken/|/ms/chuko/|nc="))
        url = urljoin(base_url, a["href"]) if a and a.get("href") else ""

        # 階: 所在階・階建（ラベルまたは本文・物件名から）
        body_text = bloc.get_text()
        floor_position = _parse_floor_position(get_val("所在階") or get_val("階") or body_text) or _parse_floor_position(name)
        floor_total = _parse_floor_total(get_val("階建") or get_val("建物階数") or body_text) or _parse_floor_total(name)
        # 権利形態: 所有権・借地権・底地権等（一覧に表示されていれば取得）
        ownership_raw = get_val("権利形態") or ""
        ownership = (ownership_raw.strip() or None) if ownership_raw.strip() else None

        return SuumoListing(
            source="suumo",
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
            total_units=None,
            floor_position=floor_position,
            floor_total=floor_total,
            ownership=ownership,
        )
    except Exception:
        return None


def _parse_cassette(div, base_url: str) -> Optional[SuumoListing]:
    """cassetteitem っぽい div から1件分を取り出す。"""
    try:
        title_el = div.find(class_=re.compile(r"content-title|title|cassetteitem_content-title"))
        name = (title_el.get_text(strip=True) or "").strip() if title_el else ""

        # 価格
        price_el = div.find(string=re.compile(r"販売価格|価格"))
        if price_el:
            parent = price_el.parent
            price_text = parent.get_text() if parent else str(price_el)
        else:
            price_text = div.get_text()
        price_man = _parse_price(price_text)

        # リンク
        a = div.find("a", href=re.compile(r"/jj/bukken/|/ms/chuko/|nc="))
        url = urljoin(base_url, a["href"]) if a and a.get("href") else ""

        # 住所・駅・徒歩
        addr_el = div.find(class_=re.compile(r"detail-col1|address|address"))
        address = (addr_el.get_text(strip=True) or "") if addr_el else ""
        col2 = div.find(class_=re.compile(r"detail-col2|station|access"))
        station_line = (col2.get_text(strip=True) or "") if col2 else ""
        walk_min = _parse_walk_min(station_line or div.get_text())

        # 専有・間取り・築年
        body = div.get_text()
        area_m2 = _parse_area_m2(body)
        layout = ""
        for part in re.split(r"[\s\n]+", body):
            if re.match(r"^[0-9]+[LDK DK]+$", part.replace(" ", "")):
                layout = part.strip()
                break
        if not layout:
            m = re.search(r"間取り\s*([0-9]+[LDK DK]+)", body)
            if m:
                layout = m.group(1).strip()

        built_m = re.search(r"築年月\s*([0-9]{4}\s*年[0-9]{1,2}\s*月?)", body)
        built_str = built_m.group(1).strip() if built_m else ""
        built_year = _parse_built_year(built_str)
        floor_position = _parse_floor_position(body) or _parse_floor_position(name or "")
        floor_total = _parse_floor_total(body) or _parse_floor_total(name or "")

        return SuumoListing(
            source="suumo",
            url=url,
            name=name or "（不明）",
            price_man=price_man,
            address=address,
            station_line=station_line,
            walk_min=walk_min,
            area_m2=area_m2,
            layout=layout,
            built_str=built_str,
            built_year=built_year,
            total_units=None,
            floor_position=floor_position,
            floor_total=floor_total,
            ownership=None,
        )
    except Exception:
        return None


def _parse_property_block(bloc, base_url: str) -> Optional[SuumoListing]:
    """property / bukken 系ブロックから1件取り出す。"""
    text = bloc.get_text()
    price_man = _parse_price(text)
    area_m2 = _parse_area_m2(text)
    walk_min = _parse_walk_min(text)
    built_year = _parse_built_year(text)
    a = bloc.find("a", href=True)
    url = urljoin(base_url, a["href"]) if a else ""

    name_el = bloc.find(class_=re.compile(r"title|name|content-title"))
    name = (name_el.get_text(strip=True) or "").strip() if name_el else ""

    m = re.search(r"間取り\s*([^\s]+)", text)
    layout = (m.group(1).strip() if m else "").strip()

    built_m = re.search(r"([0-9]{4}\s*年[0-9]{1,2}\s*月?)", text)
    built_str = built_m.group(1).strip() if built_m else ""
    floor_position = _parse_floor_position(text) or _parse_floor_position(name or "")
    floor_total = _parse_floor_total(text) or _parse_floor_total(name or "")

    return SuumoListing(
        source="suumo",
        url=url,
        name=name or "（不明）",
        price_man=price_man,
        address="",
        station_line="",
        walk_min=walk_min,
        area_m2=area_m2,
        layout=layout,
        built_str=built_str,
        built_year=built_year,
        total_units=None,
        floor_position=floor_position,
        floor_total=floor_total,
        ownership=None,
    )


def _parse_fallback(soup: BeautifulSoup, base_url: str) -> list[SuumoListing]:
    """タイトル・価格・専有・間取り・築年を含むテキストブロックから推定でリスト化。"""
    items = []
    # 見出しまたは「物件名」「販売価格」を含むセクションをブロックとして扱う
    for wrap in soup.find_all(["div", "section", "li"], class_=True):
        txt = wrap.get_text()
        if "販売価格" not in txt and "万円" not in txt:
            continue
        price_man = _parse_price(txt)
        if price_man is None:
            continue
        area_m2 = _parse_area_m2(txt)
        walk_min = _parse_walk_min(txt)
        built_year = _parse_built_year(txt)
        m = re.search(r"間取り\s*([^\s]+)", txt)
        layout = (m.group(1).strip() if m else "").strip()

        built_m = re.search(r"([0-9]{4}\s*年[0-9]{1,2}\s*月?)", txt)
        built_str = built_m.group(1).strip() if built_m else ""

        link = wrap.find("a", href=re.compile(r"/jj/bukken/|/ms/chuko/|nc="))
        url = urljoin(base_url, link["href"]) if link and link.get("href") else ""

        name_el = wrap.find(class_=re.compile(r"title|content-title|name"))
        name = (name_el.get_text(strip=True) or "").strip() if name_el else ""
        if not name:
            for h in wrap.find_all(["h2", "h3", "h4"]):
                t = h.get_text(strip=True)
                if t and len(t) < 100 and "万円" not in t:
                    name = t
                    break
        floor_position = _parse_floor_position(txt) or _parse_floor_position(name or "")
        floor_total = _parse_floor_total(txt) or _parse_floor_total(name or "")

        items.append(
            SuumoListing(
                source="suumo",
                url=url,
                name=name or "（不明）",
                price_man=price_man,
                address="",
                station_line="",
                walk_min=walk_min,
                area_m2=area_m2,
                layout=layout,
                built_str=built_str,
                built_year=built_year,
                total_units=None,
                floor_position=floor_position,
                floor_total=floor_total,
                ownership=None,
            )
        )
    return items


def parse_suumo_detail_html(html: str) -> dict[str, Optional[int]]:
    """SUUMO 物件詳細ページのHTMLから「総戸数」「所在階」「構造・階建」をパースする。

    詳細ページを自動取得する機能は含まない。HTML文字列を渡して利用する。
    戻り値: {"total_units": int|None, "floor_position": int|None, "floor_total": int|None, "floor_structure": str|None}
    floor_structure は "RC13階地下1階建" など表示用文字列（format_floor で 12階/RC13階地下1階建 にする際に使用）。

    想定HTML構造（docs/suumo.html 参照）:
    - th に「総戸数」を含む行の直後 td → "38戸" など → total_units
    - th に「所在階」または「所在階/構造・階建」を含む行の td → "12階" または "12階/RC13階地下1階建" → floor_position, 必要なら floor_total
    - th に「構造・階建て」を含む行の td → "RC13階地下1階建" など → floor_total
    """
    soup = BeautifulSoup(html, "lxml")
    total_units: Optional[int] = None
    floor_position: Optional[int] = None
    floor_total: Optional[int] = None
    floor_structure: Optional[str] = None

    for tr in soup.find_all("tr"):
        cells = tr.find_all(["th", "td"], recursive=False)
        for i, cell in enumerate(cells):
            if cell.name != "th" or i + 1 >= len(cells) or cells[i + 1].name != "td":
                continue
            th_text = (cell.get_text() or "").strip()
            td_text = (cells[i + 1].get_text() or "").strip()

            if "総戸数" in th_text:
                m = re.search(r"(\d+)\s*戸", td_text)
                if m:
                    total_units = int(m.group(1))

            if "所在階" in th_text:
                m = re.search(r"(\d+)\s*階", td_text)
                if m:
                    floor_position = int(m.group(1))
                m2 = re.search(r"(?:RC|SRC|鉄骨)?(\d+)\s*階(?:\s*地下\d+階)?\s*建", td_text)
                if m2:
                    floor_total = int(m2.group(1))
                # "12階/RC13階地下1階建" の形式なら / 以降を構造として保存
                if "/" in td_text:
                    after_slash = td_text.split("/", 1)[1].strip()
                    if after_slash:
                        floor_structure = after_slash

            if "構造・階建" in th_text:
                # 「RC13階地下1階建」のように「○階建」で終わる部分から階数を取る（所在階の「12階」にマッチしないよう）
                m = re.search(r"(?:RC|SRC|鉄骨)?(\d+)\s*階(?:\s*地下\d+階)?\s*建", td_text)
                if m:
                    floor_total = int(m.group(1))
                # 「所在階/構造・階建」の同一セルでなく、別行の「構造・階建て」セルなら td 全体を構造とする
                if "所在階" not in th_text and td_text.strip():
                    floor_structure = td_text.strip()

    return {
        "total_units": total_units,
        "floor_position": floor_position,
        "floor_total": floor_total,
        "floor_structure": floor_structure,
    }


def _is_tokyo_23(address: str, url: str = "", list_ward_roman: Optional[str] = None) -> bool:
    """東京23区の物件かどうか。住所・URL・一覧取得元の区で判定する。"""
    url_lower = (url or "").lower()
    # URL に他県パスが含まれる場合は除外（横浜・千葉等）
    if any(path in url_lower for path in NON_TOKYO_23_URL_PATHS):
        return False
    # 区ごと一覧（sc_板橋 等）で取得した行はその区の物件とみなす（住所に区名が無い場合の救済）
    if list_ward_roman and list_ward_roman in SUUMO_23_WARD_ROMAN:
        return True
    # 住所に23区の区名が含まれる場合は採用
    if address and any(ward in address for ward in TOKYO_23_WARDS):
        return True
    # 住所が空でも URL が /tokyo/ なら採用（一覧の住所パース失敗時の救済）
    if not (address or "").strip() and "/tokyo/" in url_lower:
        return True
    return False


def _line_ok(station_line: str) -> bool:
    """路線限定時、最寄り路線がALLOWED_LINE_KEYWORDSのいずれかを含むか。空のときは通過（パース失敗時の取りこぼし防止）。"""
    if not ALLOWED_LINE_KEYWORDS:
        return True
    line = (station_line or "").strip()
    if not line:
        return True  # 一覧で沿線・駅が取れない場合は通過（SUUMO HTML変更等で全件落ちるのを防ぐ）
    return any(kw in line for kw in ALLOWED_LINE_KEYWORDS)


def _load_building_units_cache() -> dict[str, int]:
    """data/building_units.json から URL → 総戸数 のキャッシュを読み込む。"""
    cache_path = Path(__file__).resolve().parent / "data" / "building_units.json"
    if not cache_path.exists():
        return {}
    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


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
        return True  # データにない駅は通過（取りこぼし防止）
    return passengers >= STATION_PASSENGERS_MIN


def apply_conditions(listings: list[SuumoListing]) -> list[SuumoListing]:
    """価格・専有・間取り・築年・徒歩・地域（東京23区）・総戸数・駅乗降客数で条件ドキュメントに合わせてフィルタ。"""
    units_cache = _load_building_units_cache()
    passengers_map = _load_station_passengers()
    out = []
    for r in listings:
        list_ward = getattr(r, "list_ward_roman", None)
        if not _is_tokyo_23(r.address, r.url, list_ward_roman=list_ward):
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
        total_units = r.total_units if r.total_units is not None else units_cache.get(r.url)
        if total_units is not None and total_units < TOTAL_UNITS_MIN:
            continue
        if total_units is not None:
            r.total_units = total_units
        out.append(r)
    return out


# 全ページ取得時の安全上限（無限ループ防止）
SUUMO_MAX_PAGES_SAFETY = 100


def scrape_suumo(max_pages: Optional[int] = 3, apply_filter: bool = True) -> Iterator[SuumoListing]:
    """SUUMO 東京23区の中古マンションを取得。全23区を sc_区のローマ字（sc_koto, sc_kita 等）で同様に区ごとに取得。max_pages=0 のときは結果がなくなるまで全ページ取得。"""
    session = _session()
    seen_urls: set[str] = set()
    limit = max_pages if max_pages and max_pages > 0 else SUUMO_MAX_PAGES_SAFETY
    for ward_roman in SUUMO_23_WARD_ROMAN:  # 全23区を同じ方式で取得
        p = 1
        while p <= limit:
            html = fetch_list_page(session, p, ward_roman=ward_roman)
            rows = parse_list_html(html)
            if not rows:
                break
            passed = 0
            for row in rows:
                row.list_ward_roman = ward_roman  # 区ごと一覧のため、住所に区名が無くても23区判定に利用
                if row.url and row.url not in seen_urls:
                    seen_urls.add(row.url)
                    if apply_filter:
                        filtered = apply_conditions([row])
                        if filtered:
                            yield filtered[0]
                            passed += 1
                    else:
                        yield row
                        passed += 1
            if apply_filter and rows and passed == 0:
                print(f"SUUMO: sc_{ward_roman} ページ{p}で{len(rows)}件パースしたが条件通過0件。", file=__import__("sys").stderr)
            p += 1