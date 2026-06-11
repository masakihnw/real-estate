#!/usr/bin/env python3
"""
HOME'S 物件詳細ページから画像（間取り図+物件写真）を取得する enricher。

SUUMO の間取り図は build_units_cache.py → merge_detail_cache.py 経由で付与されるため、
このスクリプトでは HOME'S のみを対象とする。

HOME'S 詳細ページのHTML取得・パース・キャッシュの正はこのモジュール
（HomesDetailFetcher / parse_homes_*）。homes_image_backfill.py と
.github/workflows/backfill-homes-images.yml もここを参照する（実装の三重管理禁止）。

使い方:
  python floor_plan_enricher.py --input results/latest.json --output results/latest.json
"""

import argparse
import hashlib
import json
import re
import sys
import time
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin

from bs4 import BeautifulSoup

from config import (
    HOMES_REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
)
from scraper_common import create_session, is_waf_challenge

from logger import get_logger
logger = get_logger(__name__)

try:
    from playwright.sync_api import sync_playwright  # noqa: F401
    HAS_PLAYWRIGHT = True
except ImportError:
    HAS_PLAYWRIGHT = False

ROOT = Path(__file__).resolve().parent
CACHE_DIR = ROOT / "data" / "homes_html_cache"
MANIFEST_PATH = CACHE_DIR / "manifest.json"


def _url_to_hash(url: str) -> str:
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def _load_manifest() -> dict[str, str]:
    if not MANIFEST_PATH.exists():
        return {}
    try:
        with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def _save_manifest(manifest: dict[str, str]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)


def _read_cached_html(url: str, manifest: dict[str, str]) -> Optional[str]:
    h = manifest.get(url)
    if not h:
        return None
    path = CACHE_DIR / f"{h}.html"
    if not path.exists():
        return None
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def _write_html_cache(url: str, html: str, manifest: dict[str, str]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    h = _url_to_hash(url)
    path = CACHE_DIR / f"{h}.html"
    path.write_text(html, encoding="utf-8")
    manifest[url] = h
    _save_manifest(manifest)


class HomesDetailFetcher:
    """HOME'S 詳細ページの HTML 取得（Playwright ステルス優先・HTMLキャッシュ共有）。

    一覧スクレイプ（homes_scraper）は Playwright で WAF チャレンジを回避できている
    一方、画像エンリッチは requests 直叩きで JS チャレンジを解決できず、待機リトライで
    1URLあたり最大約7.5分を浪費していた（実測: 1ランで WAF 待機32回・2653秒）。
    取得経路を Playwright に統一し、WAF 検知時はリトライせず即 None を返して
    呼び出し元のサーキットブレーカー（連続N回で中断）に委ねる。
    """

    def __init__(self, delay_sec: float = HOMES_REQUEST_DELAY_SEC):
        self.delay_sec = delay_sec
        self.manifest = _load_manifest()
        self._pw = None
        self._browser = None
        self._context = None
        self._session = None  # Playwright 未導入環境の requests フォールバック

    def fetch(self, url: str) -> tuple[Optional[str], bool]:
        """(html, from_cache) を返す。WAF・取得失敗時は (None, False)。

        キャッシュヒット時はリクエストを発行しない（ディレイなし）。
        """
        cached = _read_cached_html(url, self.manifest)
        if cached is not None:
            return cached, True

        time.sleep(self.delay_sec)
        html = self._fetch_playwright(url) if HAS_PLAYWRIGHT else self._fetch_requests(url)
        if html is None:
            return None, False
        _write_html_cache(url, html, self.manifest)
        return html, False

    def _ensure_context(self):
        if self._context is None:
            from scraper_common import launch_stealth_browser
            self._pw, self._browser, self._context = launch_stealth_browser(
                referer="https://www.homes.co.jp/",
            )
        return self._context

    def _fetch_playwright(self, url: str) -> Optional[str]:
        try:
            context = self._ensure_context()
            page = context.new_page()
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=30000)
                try:
                    # 画像が lazy-load されるため、物件画像の出現を少しだけ待つ
                    page.wait_for_selector("img[src*='homes.jp']", timeout=10000)
                except Exception:
                    pass  # 画像なしページもあるため致命的ではない
                html = page.content()
            finally:
                page.close()
        except Exception as e:
            logger.error(f"  Playwright取得失敗 {url[:60]}...: {e}")
            return None
        if is_waf_challenge(html) or len(html) < 1000:
            logger.warning(f"  WAFチャレンジ検出（リトライせず中断カウントに委ねる）: {url[:60]}...")
            return None
        return html

    def _fetch_requests(self, url: str) -> Optional[str]:
        """Playwright 未導入環境のフォールバック。

        requests では WAF の JS チャレンジを解決できないため、検知したら
        待機リトライせず即諦める（旧実装は最大7.5分/URL を浪費していた）。
        """
        if self._session is None:
            self._session = create_session()
        try:
            r = self._session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            if r.status_code == 429:
                retry_after = min(int(r.headers.get("Retry-After", 60)), 120)
                logger.warning(f"  429 Rate Limited, waiting {retry_after}s")
                time.sleep(retry_after)
                r = self._session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            html = r.text
        except Exception as e:
            logger.error(f"  requests取得失敗 {url[:60]}...: {e}")
            return None
        if is_waf_challenge(html):
            logger.warning("  WAFチャレンジ検出（requestsでは解決不能のため即中断カウントに委ねる）")
            return None
        return html

    def close(self) -> None:
        try:
            if self._browser is not None:
                self._browser.close()
        except Exception:
            pass
        try:
            if self._pw is not None:
                self._pw.stop()
        except Exception:
            pass
        self._pw = self._browser = self._context = None


def parse_homes_floor_plan_images(html: str, base_url: str = "https://www.homes.co.jp") -> list[str]:
    """HOME'S 物件詳細 HTML から間取り図画像 URL を抽出する。

    HOME'S の間取り図は以下の場所に存在する:
    1. #floorplan セクション内の img タグ
    2. 間取り図タブ内の img タグ
    3. alt 属性に「間取」を含む img タグ
    4. data-src / src 属性に "floorplan" / "madori" を含む img タグ
    """
    soup = BeautifulSoup(html, "lxml")
    urls: list[str] = []
    seen: set[str] = set()

    def _add_url(raw_url: str) -> None:
        if not raw_url or raw_url.startswith("data:"):
            return
        url = urljoin(base_url, raw_url)
        # 小さいプレースホルダー画像を除外（1x1 pixel 等）
        if "noimage" in url.lower() or "spacer" in url.lower():
            return
        if url not in seen:
            seen.add(url)
            urls.append(url)

    # 方法1: id="floorplan" または class に floorplan を含むセクション内の画像
    for container in soup.find_all(id=re.compile(r"floorplan", re.I)):
        for img in container.find_all("img"):
            _add_url(img.get("data-src") or img.get("src") or "")
    for container in soup.find_all(class_=re.compile(r"floorplan|floor-plan", re.I)):
        for img in container.find_all("img"):
            _add_url(img.get("data-src") or img.get("src") or "")

    # 方法2: alt に「間取」を含む img タグ
    for img in soup.find_all("img"):
        alt = (img.get("alt") or "").strip()
        if "間取" in alt:
            _add_url(img.get("data-src") or img.get("src") or "")

    # 方法3: src/data-src に floorplan / madori を含む img タグ
    for img in soup.find_all("img"):
        src = img.get("data-src") or img.get("src") or ""
        if re.search(r"floorplan|madori|floor_plan", src, re.I):
            _add_url(src)

    # 方法4: 「間取り」リンク（a タグ）のhrefが画像ファイルの場合
    for a in soup.find_all("a", href=True):
        text = (a.get_text() or "").strip()
        href = a.get("href", "")
        if "間取" in text and re.search(r"\.(jpg|jpeg|png|gif|webp)(\?|$)", href, re.I):
            _add_url(href)
        # リンク内の img タグ
        if "間取" in text:
            for img in a.find_all("img"):
                _add_url(img.get("data-src") or img.get("src") or "")

    # 方法5: picture > source タグの srcset から間取り図を取得
    for picture in soup.find_all("picture"):
        parent_text = ""
        p = picture.parent
        for _ in range(5):
            if p is None:
                break
            parent_text = (p.get("id") or "") + " " + " ".join(p.get("class", []))
            if "floorplan" in parent_text.lower() or "間取" in (p.get_text() or ""):
                for source in picture.find_all("source"):
                    srcset = source.get("srcset", "")
                    # srcset の最初の URL を取得
                    first_url = srcset.split(",")[0].strip().split(" ")[0]
                    if first_url:
                        _add_url(first_url)
                for img in picture.find_all("img"):
                    _add_url(img.get("src") or "")
                break
            p = p.parent

    return urls


_HOMES_IMAGE_DOMAIN_RE = re.compile(r"^https?://image\d?\.homes\.jp/")
_HOMES_SIZE_PARAMS = re.compile(r"[&?](width|height|modify_date)=[^&]*")
_HOMES_TRAILING_AMP = re.compile(r"[&?]$")

_HOMES_PROPERTY_PATH_PATTERNS = (
    "/sale/image/",
    "%2Fsale%2Fimage%2F",
    "/premium/image/",
    # 中古物件: img.homes.jp/{company}/sale/{listing}/ (URL-encoded)
    "%2Fsale%2F",
)

_HOMES_JUNK_LABELS = frozenset({"HOME'S", "LIFULL HOME'S", "ホームズ", ""})


def _normalize_homes_image_url(raw_url: str) -> Optional[str]:
    """HOME'S 画像 URL からサイズパラメータを除去して正規化する。

    homes.jp ドメインの画像でなければ None を返す。
    """
    if not raw_url or raw_url.startswith("data:"):
        return None
    if not _HOMES_IMAGE_DOMAIN_RE.search(raw_url):
        return None
    normalized = _HOMES_SIZE_PARAMS.sub("", raw_url)
    normalized = _HOMES_TRAILING_AMP.sub("", normalized)
    return normalized


def parse_homes_property_images(
    html: str, base_url: str = "https://www.homes.co.jp"
) -> list[dict[str, str]]:
    """HOME'S 詳細ページから物件写真（間取り図を除く）を抽出する。

    Returns:
        [{"url": "...", "label": "..."}, ...] — 間取り図は含まない。
    """
    soup = BeautifulSoup(html, "lxml")
    images: list[dict[str, str]] = []
    seen_normalized: set[str] = set()

    # 関連物件カルーセル（splide）内の img を除外対象とする
    related_imgs: set[int] = set()
    for carousel in soup.find_all(class_=re.compile(r"splide")):
        for img in carousel.find_all("img"):
            related_imgs.add(id(img))

    for img in soup.find_all("img"):
        if id(img) in related_imgs:
            continue

        raw_url = (img.get("data-src") or img.get("src") or "").strip()
        alt = (img.get("alt") or "").strip()

        normalized = _normalize_homes_image_url(raw_url)
        if normalized is None:
            continue

        if "間取" in alt or "_madori" in raw_url:
            continue

        if normalized in seen_normalized:
            continue

        if not any(pat in raw_url for pat in _HOMES_PROPERTY_PATH_PATTERNS):
            continue

        seen_normalized.add(normalized)

        label = alt
        if not label or label in _HOMES_JUNK_LABELS:
            label = "外観"

        images.append({"url": raw_url, "label": label})

    return images


def _needs_image_enrichment(listing: dict) -> bool:
    """HOME'S 物件が画像エンリッチメントの対象かどうかを判定する。"""
    if not isinstance(listing, dict):
        return False
    if listing.get("source") != "homes":
        return False
    if not listing.get("url"):
        return False
    has_fp = bool(listing.get("floor_plan_images"))
    has_prop = bool(listing.get("suumo_images"))
    return not has_fp or not has_prop


def main() -> None:
    parser = argparse.ArgumentParser(description="HOME'S 画像 enricher（間取り図+物件写真）")
    parser.add_argument("--input", required=True, help="入力 JSON ファイル")
    parser.add_argument("--output", required=True, help="出力 JSON ファイル")
    parser.add_argument("--limit", type=int, default=0,
                        help="処理上限件数（0=無制限）。CI 環境での timeout 防止用")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        logger.info(f"入力ファイルがありません: {input_path}")
        sys.exit(1)

    with open(input_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        logger.info("JSON は配列である必要があります")
        sys.exit(1)

    homes_listings = [
        (i, r) for i, r in enumerate(listings)
        if _needs_image_enrichment(r)
    ]

    if args.limit and args.limit > 0:
        homes_listings = homes_listings[:args.limit]

    if not homes_listings:
        logger.info("HOME'S で画像未取得の物件はありません")
        sys.exit(0)

    logger.info(
        f"HOME'S 画像取得: {len(homes_listings)}件の詳細ページを処理します"
        f"（取得経路: {'Playwright' if HAS_PLAYWRIGHT else 'requests フォールバック'}）"
    )

    fetcher = HomesDetailFetcher()
    enriched_fp = 0
    enriched_prop = 0
    fetched = 0
    consecutive_waf = 0

    try:
        for idx, (list_idx, listing) in enumerate(homes_listings):
            if consecutive_waf >= 3:
                logger.warning("WAF/取得失敗 連続3回: 残りの処理を中断します")
                break

            url = listing["url"]
            html, from_cache = fetcher.fetch(url)
            if html is None:
                consecutive_waf += 1
                continue
            consecutive_waf = 0
            if not from_cache:
                fetched += 1

            if not listing.get("floor_plan_images"):
                fp_images = parse_homes_floor_plan_images(html)
                if fp_images:
                    listings[list_idx]["floor_plan_images"] = fp_images
                    enriched_fp += 1

            if not listing.get("suumo_images"):
                prop_images = parse_homes_property_images(html)
                if prop_images:
                    listings[list_idx]["suumo_images"] = prop_images
                    enriched_prop += 1

            if (idx + 1) % 20 == 0:
                logger.info(f"  ...{idx + 1}/{len(homes_listings)}件処理済")
    finally:
        fetcher.close()

    tmp_path = output_path.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp_path.replace(output_path)

    from enrichment_writer import write_enrichments
    write_enrichments(listings, ["floor_plan_images", "suumo_images"], "homes_images")

    print(
        f"HOME'S 画像: 間取り図 {enriched_fp}件, 物件写真 {enriched_prop}件"
        f"（HTML新規取得 {fetched}件）",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
