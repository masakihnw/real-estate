"""
アットホーム（athome.co.jp）中古マンション一覧のスクレイピング。
利用規約を遵守し、負荷軽減・私的利用に留めること。
"""

import json
import re
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone, timedelta
from pathlib import Path
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

# 東京23区・中古マンション一覧（区ごとにスクレイプ）
_WARD_URL_FIRST = "https://www.athome.co.jp/mansion/chuko/13-{ward}/list/"
_WARD_URL_PAGE = "https://www.athome.co.jp/mansion/chuko/13-{ward}/list/page{page}/"

# 後方互換: 旧URL（全東京）
LIST_URL_FIRST = "https://www.athome.co.jp/mansion/chuko/tokyo/list/"
LIST_URL_PAGE = "https://www.athome.co.jp/mansion/chuko/tokyo/list/page{page}/"

# 安全上限（無限ループ防止）
MAX_PAGES_SAFETY = 50

# 早期打ち切り: 連続 N ページで新規通過0件なら残りをスキップ
EARLY_EXIT_PAGES = 10

# athome の区名スラッグ（URL用）
_ATHOME_WARD_SLUGS = (
    "chiyoda-ku", "chuo-ku", "minato-ku", "shinjuku-ku", "bunkyo-ku",
    "taito-ku", "sumida-ku", "koto-ku", "shinagawa-ku", "meguro-ku",
    "ota-ku", "setagaya-ku", "shibuya-ku", "nakano-ku", "suginami-ku",
    "toshima-ku", "kita-ku", "arakawa-ku", "itabashi-ku", "nerima-ku",
    "adachi-ku", "katsushika-ku", "edogawa-ku",
)

PARALLEL_WARD_WORKERS = 3

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
    ownership: Optional[str] = None
    listing_agent: Optional[str] = None
    suumo_images: Optional[list] = None  # [{"url": "...", "label": "..."}, ...]
    floor_plan_images: Optional[list] = None  # ["url1", "url2", ...]

    def to_dict(self):
        return asdict(self)


def fetch_list_page(session: requests.Session, page: int, *, ward: str = "") -> str:
    """一覧ページのHTMLを取得。429/5xx時はリトライする。"""
    if ward:
        url = _WARD_URL_FIRST.format(ward=ward) if page == 1 else _WARD_URL_PAGE.format(ward=ward, page=page)
    else:
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


# ---------------------------------------------------------------------------
# 詳細ページ取得・パース・キャッシュ
# ---------------------------------------------------------------------------

_DETAIL_CACHE_PATH = Path(__file__).resolve().parent / "data" / "detail_cache_athome.json"
_DETAIL_CACHE_TTL_DAYS = 90


def _load_detail_cache() -> dict[str, dict]:
    """詳細ページキャッシュを読み込む。期限切れエントリは除外する。"""
    if not _DETAIL_CACHE_PATH.exists():
        return {}
    try:
        raw = json.loads(_DETAIL_CACHE_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("athome: 詳細キャッシュ読み込みエラー: %s", e)
        return {}
    cutoff = (datetime.now(timezone.utc) - timedelta(days=_DETAIL_CACHE_TTL_DAYS)).isoformat()
    valid: dict[str, dict] = {}
    for url, entry in raw.items():
        if isinstance(entry, dict) and entry.get("cached_at", "") >= cutoff:
            valid[url] = entry
    return valid


def _save_detail_cache(cache: dict[str, dict]) -> None:
    """詳細ページキャッシュを保存する。"""
    _DETAIL_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    _DETAIL_CACHE_PATH.write_text(
        json.dumps(cache, ensure_ascii=False, indent=1),
        encoding="utf-8",
    )


def _fetch_detail_page(session: requests.Session, url: str) -> str:
    """アットホーム詳細ページのHTMLを取得する。429/5xx時はリトライする。"""
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(ATHOME_REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                backoff = min(retry_after, 120)
                logger.warning("athome detail: 429 Rate Limited, waiting %ds (attempt %d/%d)", backoff, attempt + 1, REQUEST_RETRIES)
                time.sleep(backoff)
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
        except requests.exceptions.HTTPError as e:
            if e.response is not None and e.response.status_code in (500, 502, 503) and attempt < REQUEST_RETRIES - 1:
                last_error = e
                backoff = min(2 ** (attempt + 1), 30)
                logger.warning("athome detail: HTTP %d, retrying in %ds (attempt %d/%d)", e.response.status_code, backoff, attempt + 1, REQUEST_RETRIES)
                time.sleep(backoff)
            else:
                raise
        except (requests.exceptions.ReadTimeout, requests.exceptions.ConnectTimeout, requests.exceptions.ConnectionError) as e:
            last_error = e
            if attempt < REQUEST_RETRIES - 1:
                backoff = min(2 ** (attempt + 1), 30)
                logger.warning("athome detail: %s, retrying in %ds (attempt %d/%d)", type(e).__name__, backoff, attempt + 1, REQUEST_RETRIES)
                time.sleep(backoff)
            else:
                raise last_error
    if last_error is not None:
        raise last_error
    raise RuntimeError(f"athome detail: 全 {REQUEST_RETRIES} 回のリトライが失敗しました: {url}")


def parse_athome_detail_html(html: str, url: str) -> dict:
    """アットホーム詳細ページHTMLをパースし、補足情報を返す。"""
    soup = BeautifulSoup(html, "lxml")
    management_fee: Optional[int] = None
    repair_reserve_fund: Optional[int] = None
    ownership: Optional[str] = None
    total_units: Optional[int] = None

    # テーブル行（th/td ペア）から情報を抽出
    for tr in soup.find_all("tr"):
        cells = tr.find_all(["th", "td"], recursive=False)
        for i, cell in enumerate(cells):
            if cell.name != "th" or i + 1 >= len(cells) or cells[i + 1].name != "td":
                continue
            th_text = (cell.get_text() or "").strip()
            td_text = (cells[i + 1].get_text() or "").strip()

            if "管理費" in th_text and "修繕" not in th_text:
                val = parse_monthly_yen(td_text)
                if val is not None and val > 0:
                    management_fee = val

            if "修繕積立金" in th_text:
                val = parse_monthly_yen(td_text)
                if val is not None and val > 0:
                    repair_reserve_fund = val

            if ("権利形態" in th_text or "土地権利" in th_text) and td_text.strip():
                ownership = td_text.strip()

            if "総戸数" in th_text:
                m = re.search(r"(\d+)\s*戸", td_text)
                if m:
                    total_units = int(m.group(1))

    # dt/dd ペアも探索（一部のアットホーム詳細ページはこの形式）
    for dt in soup.find_all("dt"):
        dt_text = (dt.get_text() or "").strip()
        dd = dt.find_next_sibling("dd")
        if dd is None:
            continue
        dd_text = (dd.get_text() or "").strip()

        if "管理費" in dt_text and "修繕" not in dt_text and management_fee is None:
            val = parse_monthly_yen(dd_text)
            if val is not None and val > 0:
                management_fee = val

        if "修繕積立金" in dt_text and repair_reserve_fund is None:
            val = parse_monthly_yen(dd_text)
            if val is not None and val > 0:
                repair_reserve_fund = val

        if ("権利形態" in dt_text or "土地権利" in dt_text) and dd_text.strip() and ownership is None:
            ownership = dd_text.strip()

        if "総戸数" in dt_text and total_units is None:
            m = re.search(r"(\d+)\s*戸", dd_text)
            if m:
                total_units = int(m.group(1))

    # 画像抽出
    floor_plan_images: list[str] = []
    suumo_images: list[dict[str, str]] = []
    _EXCLUDE_SRC_PARTS = ("/logo", "/btn", "/icon", "spacer.gif", "/common/", "/pagetop")

    seen_urls: set[str] = set()
    for img in soup.find_all("img"):
        alt = (img.get("alt") or "").strip()
        raw_url = (img.get("data-src") or img.get("src") or "").strip()
        if isinstance(raw_url, list):
            raw_url = raw_url[0] if raw_url else ""
        if not raw_url or raw_url.startswith("data:"):
            continue
        if any(part in raw_url for part in _EXCLUDE_SRC_PARTS):
            continue
        # athome の物件画像は通常 athome.co.jp ドメインの画像サーバーから配信される
        if "athome" not in raw_url and raw_url.startswith("/"):
            raw_url = BASE_URL + raw_url
        elif not raw_url.startswith("http"):
            continue

        if raw_url in seen_urls:
            continue
        seen_urls.add(raw_url)

        if "間取" in alt:
            floor_plan_images.append(raw_url)
        elif alt and alt not in ("", "アットホーム", "at home"):
            suumo_images.append({"url": raw_url, "label": alt})

    return {
        "management_fee": management_fee,
        "repair_reserve_fund": repair_reserve_fund,
        "ownership": ownership,
        "total_units": total_units,
        "floor_plan_images": floor_plan_images if floor_plan_images else None,
        "suumo_images": suumo_images if suumo_images else None,
    }


def enrich_athome_listings(listings: list[AthomeListing]) -> list[AthomeListing]:
    """フィルタ通過済みのリストに対し、詳細ページから追加情報を取得して付与する。"""
    if not listings:
        return listings

    cache = _load_detail_cache()
    session = create_session()
    enriched_count = 0
    cache_hit_count = 0

    for r in listings:
        url = r.url
        cached_entry = cache.get(url)

        if cached_entry is not None:
            detail = cached_entry
            cache_hit_count += 1
        else:
            try:
                html = _fetch_detail_page(session, url)
                detail = parse_athome_detail_html(html, url)
            except Exception as e:
                logger.warning("athome detail: 詳細取得に失敗: %s (%s)", url, e)
                continue
            detail["cached_at"] = datetime.now(timezone.utc).isoformat()
            cache[url] = detail

        # None/空のフィールドのみ上書き
        if r.management_fee is None and detail.get("management_fee") is not None:
            r.management_fee = detail["management_fee"]
        if r.repair_reserve_fund is None and detail.get("repair_reserve_fund") is not None:
            r.repair_reserve_fund = detail["repair_reserve_fund"]
        if r.ownership is None and detail.get("ownership") is not None:
            r.ownership = detail["ownership"]
        if r.total_units is None and detail.get("total_units") is not None:
            r.total_units = detail["total_units"]
        if r.floor_plan_images is None and detail.get("floor_plan_images") is not None:
            r.floor_plan_images = detail["floor_plan_images"]
        if r.suumo_images is None and detail.get("suumo_images") is not None:
            r.suumo_images = detail["suumo_images"]

        enriched_count += 1

    _save_detail_cache(cache)
    logger.info(
        "athome detail: enrichment完了 — %d件処理 (キャッシュヒット: %d件, 新規取得: %d件)",
        enriched_count, cache_hit_count, enriched_count - cache_hit_count,
    )
    return listings


def apply_conditions(listings: list[AthomeListing]) -> list[AthomeListing]:
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


def _scrape_ward(ward: str, max_pages: int, apply_filter: bool) -> list[AthomeListing]:
    """1区分のスクレイピング。"""
    session = create_session()
    limit = max_pages if max_pages > 0 else MAX_PAGES_SAFETY
    results: list[AthomeListing] = []
    page = 1
    pages_since_last_pass = 0

    while page <= limit:
        try:
            html = fetch_list_page(session, page, ward=ward)
        except Exception as e:
            logger.error(f"athome/{ward}: ページ{page}でエラー: {e}")
            break

        rows = parse_list_html(html)
        if not rows:
            break

        passed = 0
        for row in rows:
            if apply_filter:
                filtered = apply_conditions([row])
                if filtered:
                    results.append(filtered[0])
                    passed += 1
            else:
                results.append(row)
                passed += 1

        if passed > 0:
            pages_since_last_pass = 0
        else:
            pages_since_last_pass += 1
        if pages_since_last_pass >= EARLY_EXIT_PAGES:
            break

        page += 1

    if results:
        logger.info(f"athome/{ward}: {len(results)}件通過")
    return results


def scrape_athome(max_pages: Optional[int] = 2, apply_filter: bool = True) -> Iterator[AthomeListing]:
    """アットホーム東京23区中古マンション一覧を区ごとに取得。max_pages=0 で全ページ取得。"""
    from concurrent.futures import ThreadPoolExecutor, as_completed

    limit = max_pages if max_pages and max_pages > 0 else MAX_PAGES_SAFETY
    total_passed = 0
    seen_urls: set[str] = set()

    with ThreadPoolExecutor(max_workers=PARALLEL_WARD_WORKERS) as executor:
        futures = {
            executor.submit(_scrape_ward, ward, limit, apply_filter): ward
            for ward in _ATHOME_WARD_SLUGS
        }
        for future in as_completed(futures):
            ward = futures[future]
            try:
                results = future.result()
                for r in results:
                    if r.url in seen_urls:
                        continue
                    seen_urls.add(r.url)
                    total_passed += 1
                    yield r
            except Exception as e:
                logger.error(f"athome/{ward}: エラー: {e}")

    logger.info(f"athome: 完了 — {total_passed}件通過（全23区）")
