#!/usr/bin/env python3
"""
SUUMO 物件詳細ページから総戸数・所在階・階建・権利形態を取得し、
HTML を data/html_cache/ にキャッシュ、パース結果を data/building_units.json に保存する。

- キャッシュに HTML がある URL は再取得せず、ローカルの HTML からパースする。
- キャッシュにない URL は HTTP 取得し、取得した HTML を保存してからパースする。
- building_units.json の形式: URL → 数値（従来互換）または URL → { "total_units", "floor_position", "floor_total", "floor_structure", "ownership" }

使い方:
  python scripts/build_units_cache.py                    # results/latest.json の URL を対象
  python scripts/build_units_cache.py results/xxx.json  # 指定 JSON を対象
"""

import hashlib
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Optional

import requests

# スクリプト配置が scraping-tool/ である前提
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from config import REQUEST_DELAY_SEC, REQUEST_TIMEOUT_SEC, REQUEST_RETRIES, USER_AGENT
from suumo_scraper import parse_suumo_detail_html

CACHE_DIR = ROOT / "data" / "html_cache"
MANIFEST_PATH = CACHE_DIR / "manifest.json"
ETAG_PATH = CACHE_DIR / "etags.json"
BUILDING_UNITS_PATH = ROOT / "data" / "building_units.json"

STALE_DAYS = 7  # この日数以上キャッシュされた HTML を再検証対象にする


def _url_to_hash(url: str) -> str:
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def _load_manifest() -> dict[str, str]:
    """url → hash のマッピングを読み込む。"""
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


def _load_etags() -> dict[str, dict]:
    """url → {"etag": str, "last_modified": str, "cached_at": str} を読み込む。"""
    if not ETAG_PATH.exists():
        return {}
    try:
        with open(ETAG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def _save_etags(etags: dict[str, dict]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with open(ETAG_PATH, "w", encoding="utf-8") as f:
        json.dump(etags, f, ensure_ascii=False, indent=2)


def _read_cached_html(url: str, manifest: dict[str, str]) -> Optional[str]:
    """キャッシュに HTML があれば読み込んで返す。"""
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


def _write_html_cache(url: str, html: str, manifest: dict[str, str], manifest_lock: Optional[Lock] = None) -> None:
    """HTML をキャッシュに保存し、manifest を更新する。"""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    h = _url_to_hash(url)
    path = CACHE_DIR / f"{h}.html"
    path.write_text(html, encoding="utf-8")
    if manifest_lock:
        with manifest_lock:
            manifest[url] = h
    else:
        manifest[url] = h


def fetch_detail(
    session: requests.Session,
    url: str,
    etag: Optional[str] = None,
    last_modified: Optional[str] = None,
) -> tuple[Optional[str], Optional[str], Optional[str]]:
    """詳細ページの HTML を取得。ETag/Last-Modified による条件付きリクエストに対応。

    Returns:
        (html, etag, last_modified) — 304 の場合は (None, None, None) を返す。
    """
    session.headers["User-Agent"] = USER_AGENT
    headers: dict[str, str] = {}
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified

    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC, headers=headers)

            if r.status_code == 304:
                return (None, None, None)

            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                backoff = min(retry_after, 120)
                if attempt < REQUEST_RETRIES - 1:
                    time.sleep(backoff)
                    continue
                raise requests.exceptions.HTTPError(
                    f"429 Rate Limited after {REQUEST_RETRIES} attempts", response=r
                )
            if 500 <= r.status_code < 600 and attempt < REQUEST_RETRIES - 1:
                last_error = requests.exceptions.HTTPError(
                    f"Server error {r.status_code}", response=r
                )
                backoff = min(2 ** (attempt + 1), 30)
                time.sleep(backoff)
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            resp_etag = r.headers.get("ETag")
            resp_lm = r.headers.get("Last-Modified")
            return (r.text, resp_etag, resp_lm)
        except (
            requests.exceptions.ReadTimeout,
            requests.exceptions.ConnectTimeout,
            requests.exceptions.ConnectionError,
        ) as e:
            last_error = e
            if attempt < REQUEST_RETRIES - 1:
                backoff = min(2 ** (attempt + 1), 30)
                time.sleep(backoff)
            else:
                raise
        except requests.exceptions.HTTPError:
            raise
    if last_error is not None:
        raise last_error
    raise RuntimeError(f"全 {REQUEST_RETRIES} 回のリトライが失敗しました: {url}")


def _detail_to_cache_entry(parsed: dict) -> dict:
    """parse_suumo_detail_html の戻り値を building_units.json 用のエントリに変換。None は含めない。"""
    entry = {}
    _SCALAR_KEYS = (
        "total_units", "floor_position", "floor_total", "floor_structure",
        "ownership", "management_fee", "repair_reserve_fund",
        "direction", "balcony_area_m2", "parking", "constructor", "zoning",
        "repair_fund_onetime", "delivery_date",
    )
    for key in _SCALAR_KEYS:
        if parsed.get(key) is not None:
            entry[key] = parsed[key]
    if parsed.get("feature_tags"):
        entry["feature_tags"] = parsed["feature_tags"]
    if parsed.get("floor_plan_images"):
        entry["floor_plan_images"] = parsed["floor_plan_images"]
    if parsed.get("suumo_images"):
        entry["suumo_images"] = parsed["suumo_images"]
    return entry


CONCURRENT_WORKERS = 4


def _html_content_hash(html: str) -> str:
    """HTML コンテンツの MD5 ハッシュ（パーススキップ用）。"""
    return hashlib.md5(html.encode("utf-8")).hexdigest()


def _fetch_one(
    url: str,
    manifest: dict,
    manifest_lock: Lock,
    etags: dict,
    etag_lock: Lock,
    is_revalidation: bool = False,
) -> tuple[str, Optional[str], bool]:
    """1件の詳細ページを取得してキャッシュに保存。

    Returns:
        (url, html_or_None, was_304) — 304 の場合は html=None, was_304=True。
    """
    session = requests.Session()
    old_etag_info = etags.get(url, {})
    try:
        html, resp_etag, resp_lm = fetch_detail(
            session, url,
            etag=old_etag_info.get("etag") if is_revalidation else None,
            last_modified=old_etag_info.get("last_modified") if is_revalidation else None,
        )
        if html is None:
            # 304 Not Modified — キャッシュ日時だけ更新
            now_iso = datetime.now(timezone.utc).isoformat()
            with etag_lock:
                if url in etags:
                    etags[url]["cached_at"] = now_iso
            return (url, None, True)

        _write_html_cache(url, html, manifest, manifest_lock)
        now_iso = datetime.now(timezone.utc).isoformat()
        with etag_lock:
            etags[url] = {
                "etag": resp_etag,
                "last_modified": resp_lm,
                "cached_at": now_iso,
            }
        return (url, html, False)
    except Exception as e:
        print(f"  取得失敗 {url[:50]}...: {e}", file=sys.stderr)
        return (url, None, False)


def main() -> None:
    json_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "results" / "latest.json"
    if not json_path.exists():
        print(f"対象ファイルがありません: {json_path}", file=sys.stderr)
        sys.exit(1)

    with open(json_path, "r", encoding="utf-8") as f:
        rows = json.load(f)

    suumo_urls = [r["url"] for r in rows if isinstance(r, dict) and r.get("source") == "suumo" and r.get("url")]
    if not suumo_urls:
        print("SUUMO の URL がありません。", file=sys.stderr)
        sys.exit(0)

    BUILDING_UNITS_PATH.parent.mkdir(parents=True, exist_ok=True)
    existing: dict = {}
    if BUILDING_UNITS_PATH.exists():
        try:
            with open(BUILDING_UNITS_PATH, "r", encoding="utf-8") as f:
                raw = json.load(f)
            existing = raw
        except (json.JSONDecodeError, OSError) as e:
            print(f"警告: building_units.json の読み込みに失敗（空キャッシュで続行）: {e}", file=sys.stderr)

    # パース済み HTML のコンテンツハッシュ → 前回パース結果が同一 HTML なら再パース不要
    parse_hash_path = ROOT / "data" / "parse_hashes.json"
    parse_hashes: dict[str, str] = {}
    if parse_hash_path.exists():
        try:
            with open(parse_hash_path, "r", encoding="utf-8") as f:
                parse_hashes = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    manifest = _load_manifest()
    manifest_lock = Lock()
    etags = _load_etags()
    etag_lock = Lock()

    # 未キャッシュ URL（新規物件）
    to_fetch = [u for u in suumo_urls if _read_cached_html(u, manifest) is None]

    # キャッシュ済みだが STALE_DAYS 以上経過した URL を再検証対象に
    now = datetime.now(timezone.utc)
    to_revalidate: list[str] = []
    for u in suumo_urls:
        if u in [x for x in to_fetch]:
            continue
        info = etags.get(u, {})
        cached_at_str = info.get("cached_at")
        if not cached_at_str:
            # ETag 情報がない古いキャッシュ → 再検証対象
            to_revalidate.append(u)
            continue
        try:
            cached_at = datetime.fromisoformat(cached_at_str)
            if (now - cached_at).days >= STALE_DAYS:
                to_revalidate.append(u)
        except (ValueError, TypeError):
            to_revalidate.append(u)

    if to_fetch:
        print(
            f"フィルタ通過後のSUUMO {len(suumo_urls)}件のうち、HTML未キャッシュ {len(to_fetch)}件の詳細ページを取得します。",
            file=sys.stderr,
        )
        if len(to_fetch) == len(suumo_urls):
            print("（初回のため全件取得します）", file=sys.stderr)

    if to_revalidate:
        print(
            f"  キャッシュ済み {len(suumo_urls) - len(to_fetch)}件のうち、{len(to_revalidate)}件を ETag/条件付きリクエストで再検証します。",
            file=sys.stderr,
        )

    # Phase 1a: 未キャッシュ URL を並列フェッチ
    fetched_htmls: dict[str, str] = {}
    if to_fetch:
        with ThreadPoolExecutor(max_workers=CONCURRENT_WORKERS) as pool:
            futures = {
                pool.submit(_fetch_one, url, manifest, manifest_lock, etags, etag_lock, False): url
                for url in to_fetch
            }
            for future in as_completed(futures):
                url, html, _ = future.result()
                if html is not None:
                    fetched_htmls[url] = html

        _save_manifest(manifest)
        print(f"  HTML新規取得完了: {len(fetched_htmls)}/{len(to_fetch)}件成功", file=sys.stderr)

    # Phase 1b: 古いキャッシュを ETag で再検証
    revalidated_count = 0
    not_modified_count = 0
    if to_revalidate:
        with ThreadPoolExecutor(max_workers=CONCURRENT_WORKERS) as pool:
            futures = {
                pool.submit(_fetch_one, url, manifest, manifest_lock, etags, etag_lock, True): url
                for url in to_revalidate
            }
            for future in as_completed(futures):
                url, html, was_304 = future.result()
                if was_304:
                    not_modified_count += 1
                elif html is not None:
                    fetched_htmls[url] = html
                    revalidated_count += 1

        _save_manifest(manifest)
        print(
            f"  再検証完了: 304 Not Modified {not_modified_count}件、更新 {revalidated_count}件",
            file=sys.stderr,
        )

    _save_etags(etags)

    # Phase 2: 全 URL をパース（キャッシュ済み HTML + 新規取得 HTML）
    updated = 0
    skipped = 0

    for url in suumo_urls:
        html = fetched_htmls.get(url) or _read_cached_html(url, manifest)
        if html is None:
            continue

        # HTML 未変更ならパーススキップ（既存エントリが存在する場合のみ）
        content_hash = _html_content_hash(html)
        if url in existing and parse_hashes.get(url) == content_hash:
            skipped += 1
            continue

        parsed = parse_suumo_detail_html(html)
        entry = _detail_to_cache_entry(parsed)
        if entry:
            existing[url] = entry
            parse_hashes[url] = content_hash
            updated += 1
            units = parsed.get("total_units")
            if units is not None:
                print(f"  {url[:60]}... → {units}戸", file=sys.stderr)

    # 原子的書き込み
    tmp_path = BUILDING_UNITS_PATH.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(existing, f, ensure_ascii=False, indent=2)
    tmp_path.replace(BUILDING_UNITS_PATH)

    # パースハッシュの保存
    with open(parse_hash_path, "w", encoding="utf-8") as f:
        json.dump(parse_hashes, f, ensure_ascii=False)

    print(
        f"キャッシュ保存: {BUILDING_UNITS_PATH} ({len(existing)}件、今回{updated}件更新・{skipped}件スキップ・HTML新規取得{len(fetched_htmls)}件)",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
