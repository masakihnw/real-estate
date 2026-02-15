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
from pathlib import Path
from typing import Optional

import requests

# スクリプト配置が scraping-tool/ である前提
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from config import REQUEST_DELAY_SEC, REQUEST_TIMEOUT_SEC, REQUEST_RETRIES, USER_AGENT
from suumo_scraper import parse_suumo_detail_html

CACHE_DIR = ROOT / "data" / "html_cache"
MANIFEST_PATH = CACHE_DIR / "manifest.json"
BUILDING_UNITS_PATH = ROOT / "data" / "building_units.json"


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


def _write_html_cache(url: str, html: str, manifest: dict[str, str]) -> None:
    """HTML をキャッシュに保存し、manifest を更新する。"""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    h = _url_to_hash(url)
    path = CACHE_DIR / f"{h}.html"
    path.write_text(html, encoding="utf-8")
    manifest[url] = h
    _save_manifest(manifest)


def fetch_detail(session: requests.Session, url: str) -> str:
    """詳細ページの HTML を取得。429/5xx 時はリトライする。"""
    session.headers["User-Agent"] = USER_AGENT
    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC)
            # 429 Too Many Requests — Retry-After に従って待機
            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                if attempt < REQUEST_RETRIES - 1:
                    time.sleep(retry_after)
                    continue
                raise requests.exceptions.HTTPError(
                    f"429 Rate Limited after {REQUEST_RETRIES} attempts", response=r
                )
            # 5xx は一時的なサーバーエラーのためリトライ
            if 500 <= r.status_code < 600 and attempt < REQUEST_RETRIES - 1:
                last_error = requests.exceptions.HTTPError(
                    f"Server error {r.status_code}", response=r
                )
                time.sleep(2)
                continue
            r.raise_for_status()
            r.encoding = r.apparent_encoding or "utf-8"
            return r.text
        except (
            requests.exceptions.ReadTimeout,
            requests.exceptions.ConnectTimeout,
            requests.exceptions.ConnectionError,
        ) as e:
            last_error = e
            if attempt < REQUEST_RETRIES - 1:
                time.sleep(2)
            else:
                raise
        except requests.exceptions.HTTPError as e:
            raise
    if last_error is not None:
        raise last_error
    raise RuntimeError(f"全 {REQUEST_RETRIES} 回のリトライが失敗しました: {url}")


def _detail_to_cache_entry(parsed: dict) -> dict:
    """parse_suumo_detail_html の戻り値を building_units.json 用のエントリに変換。None は含めない。"""
    entry = {}
    if parsed.get("total_units") is not None:
        entry["total_units"] = parsed["total_units"]
    if parsed.get("floor_position") is not None:
        entry["floor_position"] = parsed["floor_position"]
    if parsed.get("floor_total") is not None:
        entry["floor_total"] = parsed["floor_total"]
    if parsed.get("floor_structure") is not None:
        entry["floor_structure"] = parsed["floor_structure"]
    if parsed.get("ownership") is not None:
        entry["ownership"] = parsed["ownership"]
    if parsed.get("management_fee") is not None:
        entry["management_fee"] = parsed["management_fee"]
    if parsed.get("repair_reserve_fund") is not None:
        entry["repair_reserve_fund"] = parsed["repair_reserve_fund"]
    if parsed.get("floor_plan_images"):
        entry["floor_plan_images"] = parsed["floor_plan_images"]
    if parsed.get("suumo_images"):
        entry["suumo_images"] = parsed["suumo_images"]
    return entry


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
            # 既存が URL → int の場合はそのまま。URL → dict もそのまま。
            existing = raw
        except (json.JSONDecodeError, OSError) as e:
            print(f"警告: building_units.json の読み込みに失敗（空キャッシュで続行）: {e}", file=sys.stderr)

    manifest = _load_manifest()
    # キャッシュにない URL 数＝初回は全件、2回目以降は新規・未キャッシュのみ
    to_fetch = [u for u in suumo_urls if _read_cached_html(u, manifest) is None]
    if to_fetch:
        print(
            f"フィルタ通過後のSUUMO {len(suumo_urls)}件のうち、HTML未キャッシュ {len(to_fetch)}件の詳細ページを取得します。",
            file=sys.stderr,
        )
        if len(to_fetch) == len(suumo_urls):
            print("（初回のため全件取得します）", file=sys.stderr)

    session = requests.Session()
    updated = 0
    fetched = 0

    for url in suumo_urls:
        html = _read_cached_html(url, manifest)
        if html is None:
            try:
                html = fetch_detail(session, url)
                _write_html_cache(url, html, manifest)
                fetched += 1
            except Exception as e:
                print(f"  取得失敗 {url[:50]}...: {e}", file=sys.stderr)
                continue

        parsed = parse_suumo_detail_html(html)
        entry = _detail_to_cache_entry(parsed)
        if entry:
            existing[url] = entry
            updated += 1
            units = parsed.get("total_units")
            if units is not None:
                print(f"  {url[:60]}... → {units}戸", file=sys.stderr)

    # 原子的書き込み
    tmp_path = BUILDING_UNITS_PATH.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(existing, f, ensure_ascii=False, indent=2)
    tmp_path.replace(BUILDING_UNITS_PATH)
    print(
        f"キャッシュ保存: {BUILDING_UNITS_PATH} ({len(existing)}件、今回{updated}件更新・HTML新規取得{fetched}件)",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
