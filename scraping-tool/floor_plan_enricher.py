#!/usr/bin/env python3
"""
HOME'S 物件詳細ページから間取り図画像 URL を取得し、listings JSON に付与する enricher。

SUUMO の間取り図は build_units_cache.py → merge_detail_cache.py 経由で付与されるため、
このスクリプトでは HOME'S のみを対象とする。

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

import requests
from bs4 import BeautifulSoup

from config import (
    HOMES_REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
    REQUEST_RETRIES,
)
from scraper_common import create_session, is_waf_challenge

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


def fetch_homes_detail(session: requests.Session, url: str) -> str:
    """HOME'S 詳細ページの HTML を取得。WAF/429/5xx 時はリトライする。"""
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES + 2):
        time.sleep(HOMES_REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                print(f"  429 Rate Limited, waiting {retry_after}s (attempt {attempt + 1})", file=sys.stderr)
                time.sleep(retry_after)
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            html = r.text
            if is_waf_challenge(html):
                wait = min(30 * (attempt + 1), 120)
                print(f"  WAF challenge detected, waiting {wait}s (attempt {attempt + 1})", file=sys.stderr)
                time.sleep(wait)
                continue
            return html
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


def main() -> None:
    parser = argparse.ArgumentParser(description="HOME'S 間取り図画像 enricher")
    parser.add_argument("--input", required=True, help="入力 JSON ファイル")
    parser.add_argument("--output", required=True, help="出力 JSON ファイル")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        print(f"入力ファイルがありません: {input_path}", file=sys.stderr)
        sys.exit(1)

    with open(input_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    if not isinstance(listings, list):
        print("JSON は配列である必要があります", file=sys.stderr)
        sys.exit(1)

    # HOME'S の物件で floor_plan_images が未取得のものを対象にする
    homes_listings = [
        (i, r) for i, r in enumerate(listings)
        if isinstance(r, dict)
        and r.get("source") == "homes"
        and r.get("url")
        and not r.get("floor_plan_images")
    ]

    if not homes_listings:
        print("HOME'S で間取り図未取得の物件はありません", file=sys.stderr)
        sys.exit(0)

    print(f"HOME'S 間取り図取得: {len(homes_listings)}件の詳細ページを取得します", file=sys.stderr)

    manifest = _load_manifest()
    session = create_session()
    enriched = 0
    fetched = 0

    for idx, (list_idx, listing) in enumerate(homes_listings):
        url = listing["url"]
        html = _read_cached_html(url, manifest)

        if html is None:
            try:
                html = fetch_homes_detail(session, url)
                _write_html_cache(url, html, manifest)
                fetched += 1
            except Exception as e:
                print(f"  取得失敗 {url[:60]}...: {e}", file=sys.stderr)
                continue

        images = parse_homes_floor_plan_images(html)
        if images:
            listings[list_idx]["floor_plan_images"] = images
            enriched += 1
            print(f"  ✓ {listing.get('name', '?')}: {len(images)}枚", file=sys.stderr)

        # 進捗表示
        if (idx + 1) % 20 == 0:
            print(f"  ...{idx + 1}/{len(homes_listings)}件処理済", file=sys.stderr)

    # 原子的書き込み
    tmp_path = output_path.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp_path.replace(output_path)

    print(
        f"HOME'S 間取り図: {enriched}件に付与（HTML新規取得{fetched}件）",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
