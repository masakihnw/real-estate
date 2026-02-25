#!/usr/bin/env python3
"""
SUUMO 新築マンション詳細ページから物件写真・間取り図画像を取得する enricher。

1. メインページ: 外観/完成予想図/モデルルーム写真 → suumo_images（サムネイル用）
2. 間取りタブ (madori/): 間取り図画像 + タイプ情報 → floor_plan_images（検索条件でフィルタ）

新築マンションの間取りタブには複数のタイプ（Aタイプ: 3LDK, Bタイプ: 1LDK 等）が
掲載されているため、検索条件（LAYOUT_PREFIX_OK）に合致する間取りのみ取得する。

使い方:
  python shinchiku_detail_enricher.py --input results/latest_shinchiku.json --output results/latest_shinchiku.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import requests
from bs4 import BeautifulSoup

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from config import (
    LAYOUT_PREFIX_OK,
    REQUEST_DELAY_SEC,
    REQUEST_TIMEOUT_SEC,
    REQUEST_RETRIES,
    USER_AGENT,
)
from scraper_common import create_session

# HTMLキャッシュ
CACHE_DIR = ROOT / "data" / "shinchiku_html_cache"
MANIFEST_PATH = CACHE_DIR / "manifest.json"
ETAG_PATH = CACHE_DIR / "etags.json"

# 除外パターン: サイトロゴ・バナー・spacer 等の非物件画像
_EXCLUDE_ALT = {"SUUMO(スーモ)", "suumo", "担当者", ""}
_EXCLUDE_SRC_PARTS = (
    "spacer.gif", "/logo", "/btn", "/close", "/inc_",
    "/pagetop", "imgover", "/common/", "/header/", "/footer/",
)


# ──────────────────────────── HTMLキャッシュ ────────────────────────────


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


def _load_etags() -> dict[str, dict]:
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


# ──────────────────────────── HTTP取得 ────────────────────────────


def _fetch_page(
    session: requests.Session,
    url: str,
    etag: Optional[str] = None,
    last_modified: Optional[str] = None,
) -> tuple[Optional[str], Optional[str], Optional[str]]:
    """ページの HTML を取得。ETag/Last-Modified による条件付きリクエストに対応。

    Returns:
        (html, etag, last_modified) — 304 の場合は (None, None, None)。
        404 の場合は ("", None, None) を返す。
    """
    extra_headers: dict[str, str] = {}
    if etag:
        extra_headers["If-None-Match"] = etag
    if last_modified:
        extra_headers["If-Modified-Since"] = last_modified

    last_error: Optional[Exception] = None
    for attempt in range(REQUEST_RETRIES):
        time.sleep(REQUEST_DELAY_SEC)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT_SEC, headers=extra_headers)

            if r.status_code == 304:
                return (None, None, None)

            if r.status_code == 429:
                retry_after = int(r.headers.get("Retry-After", 60))
                backoff = min(retry_after, 120)
                if attempt < REQUEST_RETRIES - 1:
                    print(f"  429 Rate Limited, waiting {backoff}s", file=sys.stderr)
                    time.sleep(backoff)
                    continue
                raise requests.exceptions.HTTPError(
                    f"429 Rate Limited after {REQUEST_RETRIES} attempts", response=r
                )
            if r.status_code == 404:
                return ("", None, None)
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


# ──────────────────────────── 画像抽出ユーティリティ ────────────────────────────


def _normalize_image_url(raw_url: str) -> Optional[str]:
    """SUUMO 画像 URL を正規化（大きいサイズに変更）。"""
    if not raw_url or raw_url.startswith("data:"):
        return None
    url = raw_url.strip()
    if isinstance(url, list):
        url = url[0] if url else ""
    if not url:
        return None
    # サイト画像を除外
    if any(part in url for part in _EXCLUDE_SRC_PARTS):
        return None
    # resizeImage を含まない URL は物件画像ではない可能性が高い
    if "resizeImage" not in url and "suumo.com" not in url:
        return None
    # リサイズ URL を大きいサイズに変更
    url = re.sub(r"[&?]w=\d+", "&w=1200", url)
    url = re.sub(r"[&?]h=\d+", "&h=900", url)
    return url


# ──────────────────────────── メインページパーサー ────────────────────────────


def parse_shinchiku_main_page(html: str) -> dict:
    """新築マンション詳細メインページから物件写真を抽出。

    Returns:
        {
            "suumo_images": [{"url": str, "label": str}, ...],
            "floor_plan_images": [str, ...],  # メインページの間取り図（alt に「間取り」を含む）
        }
    """
    soup = BeautifulSoup(html, "lxml")
    suumo_images: list[dict[str, str]] = []
    floor_plan_images: list[str] = []
    seen_urls: set[str] = set()

    for img in soup.find_all("img"):
        alt = (img.get("alt") or "").strip()
        if alt in _EXCLUDE_ALT:
            continue
        raw_url = (img.get("rel") or img.get("src") or "").strip()
        if isinstance(raw_url, list):
            raw_url = raw_url[0] if raw_url else ""
        url = _normalize_image_url(raw_url)
        if not url or url in seen_urls:
            continue
        seen_urls.add(url)

        if "間取り" in alt or "間取" in alt:
            floor_plan_images.append(url)
        else:
            suumo_images.append({"url": url, "label": alt})

    return {
        "suumo_images": suumo_images if suumo_images else None,
        "floor_plan_images": floor_plan_images if floor_plan_images else None,
    }


# ──────────────────────────── 間取りタブパーサー ────────────────────────────


def _layout_matches_criteria(layout: str) -> bool:
    """間取りが検索条件（LAYOUT_PREFIX_OK）に合致するか。

    LAYOUT_PREFIX_OK = ("2", "3") の場合:
    - "3LDK" → True（3で始まる）
    - "2LDK+S" → True（2で始まる）
    - "1LDK" → False（1で始まる）
    - "4LDK" → False（4で始まる）
    """
    if not layout:
        return True  # 間取り不明は通過
    layout = layout.strip()
    return any(layout.startswith(prefix) for prefix in LAYOUT_PREFIX_OK)


def parse_shinchiku_madori_page(html: str) -> list[dict]:
    """新築マンション間取りタブページから間取り図画像を抽出。

    SUUMO 新築の間取りタブには各住戸タイプの間取り図が掲載される。
    各タイプは画像 + 間取り情報（例: "Aタイプ 3LDK 67.32㎡"）を含む。

    Returns:
        [{"url": str, "layout": str, "label": str}, ...]
    """
    if not html:
        return []

    soup = BeautifulSoup(html, "lxml")
    results: list[dict] = []
    seen_urls: set[str] = set()

    # ── 戦略1: 画像ブロック（各タイプが独立したコンテナに入っている想定） ──
    # SUUMO の間取りタブでは、各タイプの間取り図が画像 + テキストのセットで配置される
    # img タグの周辺テキストから間取り情報を抽出する

    for img in soup.find_all("img"):
        alt = (img.get("alt") or "").strip()
        raw_url = (img.get("rel") or img.get("src") or "").strip()
        if isinstance(raw_url, list):
            raw_url = raw_url[0] if raw_url else ""
        url = _normalize_image_url(raw_url)
        if not url or url in seen_urls:
            continue

        # 間取り図画像かどうかの判定
        # alt に「間取り」を含むか、madori ページ上の物件画像であるか
        is_floor_plan = "間取" in alt or "タイプ" in alt or "type" in alt.lower()

        # madori ページ上では間取り図以外の画像も含まれ得るが、
        # resizeImage 系のメイン画像は間取り図の可能性が高い
        if not is_floor_plan:
            # 親要素のテキストに間取り関連キーワードがあるか
            parent = img.parent
            for _ in range(5):
                if parent is None:
                    break
                parent_text = (parent.get_text() or "")
                if re.search(r"\d[LDKS]", parent_text):
                    is_floor_plan = True
                    break
                parent = parent.parent

        if not is_floor_plan:
            continue

        seen_urls.add(url)

        # 間取り（例: "3LDK"）を近傍テキストから抽出
        layout = _extract_layout_near_image(img)
        label = alt or f"間取り図"
        if layout:
            label = f"{layout} {label}".strip()

        results.append({
            "url": url,
            "layout": layout or "",
            "label": label,
        })

    # ── 戦略2: リンク内画像（a タグ内の img） ──
    # 間取り図がサムネイルリンクになっている場合
    for a_tag in soup.find_all("a", href=True):
        href = a_tag.get("href", "")
        # 画像リンクの場合
        if not re.search(r"\.(jpg|jpeg|png|gif|webp)(\?|$)", href, re.I):
            # href が resizeImage の場合もある
            if "resizeImage" not in href:
                continue

        link_text = (a_tag.get_text() or "").strip()
        if "間取" not in link_text and "タイプ" not in link_text:
            # リンク内の img を確認
            inner_imgs = a_tag.find_all("img")
            if not inner_imgs:
                continue
            inner_alt = " ".join((im.get("alt") or "") for im in inner_imgs)
            if "間取" not in inner_alt and "タイプ" not in inner_alt:
                continue

        url = _normalize_image_url(href)
        if not url or url in seen_urls:
            continue
        seen_urls.add(url)

        layout = _extract_layout_near_image(a_tag)
        results.append({
            "url": url,
            "layout": layout or "",
            "label": f"間取り図 {layout or ''}".strip(),
        })

    return results


def _extract_layout_near_image(element) -> str:
    """img/a 要素の近傍テキストから間取り（例: "3LDK"）を抽出。"""
    # 1. alt 属性から
    alt = (element.get("alt") or "").strip()
    m = re.search(r"(\d[LDKS（納戸）R+・]+(?:\+[SN])?)", alt)
    if m:
        return m.group(1)

    # 2. 親要素のテキストから（上方向に5レベルまで探索）
    parent = element.parent
    for _ in range(6):
        if parent is None or parent.name in ("body", "html", "[document]"):
            break
        text = parent.get_text(separator=" ")
        # 間取りパターン: "3LDK", "2LDK+S", "3DK" 等
        m = re.search(r"(\d[LDKS]+(?:\+[SN（納戸）])?)", text)
        if m:
            return m.group(1)
        parent = parent.parent

    return ""


# ──────────────────────────── メイン処理 ────────────────────────────


def enrich_listing(
    session: requests.Session,
    listing: dict,
    manifest: dict[str, str],
    etags: dict[str, dict],
) -> dict:
    """1件の新築物件に対して詳細ページを取得し、画像データを付与する。

    Returns:
        {"suumo_images": [...], "floor_plan_images": [...]} or empty dict
    """
    url = listing.get("url", "")
    if not url:
        return {}

    result: dict = {}

    # ── メインページ取得 ──
    main_html = _read_cached_html(url, manifest)
    if main_html is None:
        try:
            etag_info = etags.get(url, {})
            html, resp_etag, resp_lm = _fetch_page(
                session, url,
                etag=etag_info.get("etag"),
                last_modified=etag_info.get("last_modified"),
            )
            if html is None:
                # 304 — use cached (shouldn't reach here as cache was None)
                main_html = None
            elif html:
                _write_html_cache(url, html, manifest)
                etags[url] = {
                    "etag": resp_etag,
                    "last_modified": resp_lm,
                    "cached_at": datetime.now(timezone.utc).isoformat(),
                }
                main_html = html
        except Exception as e:
            print(f"  メインページ取得失敗 {url[:60]}...: {e}", file=sys.stderr)
            main_html = None

    if main_html:
        parsed = parse_shinchiku_main_page(main_html)
        if parsed.get("suumo_images"):
            result["suumo_images"] = parsed["suumo_images"]

    # ── 間取りタブ取得 ──
    madori_url = url.rstrip("/") + "/madori/"
    madori_html = _read_cached_html(madori_url, manifest)
    if madori_html is None:
        try:
            etag_info = etags.get(madori_url, {})
            html, resp_etag, resp_lm = _fetch_page(
                session, madori_url,
                etag=etag_info.get("etag"),
                last_modified=etag_info.get("last_modified"),
            )
            if html is None:
                madori_html = None
            elif html:
                _write_html_cache(madori_url, html, manifest)
                etags[madori_url] = {
                    "etag": resp_etag,
                    "last_modified": resp_lm,
                    "cached_at": datetime.now(timezone.utc).isoformat(),
                }
                madori_html = html
            else:
                madori_html = html  # empty string for 404
        except Exception as e:
            print(f"  間取りタブ取得失敗 {madori_url[:60]}...: {e}", file=sys.stderr)
            madori_html = None

    # 間取り図画像の取得とフィルタリング
    floor_plan_images: list[str] = []

    if madori_html:
        madori_plans = parse_shinchiku_madori_page(madori_html)
        if madori_plans:
            # 検索条件に合致する間取りのみ採用
            for plan in madori_plans:
                layout = plan.get("layout", "")
                if _layout_matches_criteria(layout):
                    floor_plan_images.append(plan["url"])

            matched = len(floor_plan_images)
            total = len(madori_plans)
            if matched < total:
                print(
                    f"    間取りタブ: {total}タイプ中{matched}タイプが条件合致",
                    file=sys.stderr,
                )

    # メインページの間取り図も追加（重複除去）
    if main_html:
        parsed_main = parse_shinchiku_main_page(main_html)
        if parsed_main.get("floor_plan_images"):
            existing_urls = set(floor_plan_images)
            for fp_url in parsed_main["floor_plan_images"]:
                if fp_url not in existing_urls:
                    floor_plan_images.append(fp_url)
                    existing_urls.add(fp_url)

    if floor_plan_images:
        result["floor_plan_images"] = floor_plan_images

    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description="SUUMO 新築マンション詳細ページ enricher（写真・間取り図取得）"
    )
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

    # SUUMO 新築物件で画像未取得のものを対象にする
    targets = [
        (i, r) for i, r in enumerate(listings)
        if isinstance(r, dict)
        and r.get("source") == "suumo"
        and r.get("url")
        and (not r.get("suumo_images") or not r.get("floor_plan_images"))
    ]

    if not targets:
        print("画像未取得の SUUMO 新築物件はありません", file=sys.stderr)
        sys.exit(0)

    print(
        f"SUUMO 新築詳細取得: {len(targets)}件の詳細・間取りページを取得します",
        file=sys.stderr,
    )

    manifest = _load_manifest()
    etags = _load_etags()
    session = create_session()
    enriched_images = 0
    enriched_plans = 0

    for idx, (list_idx, listing) in enumerate(targets):
        name = listing.get("name", "?")
        result = enrich_listing(session, listing, manifest, etags)

        if result.get("suumo_images") and not listing.get("suumo_images"):
            listings[list_idx]["suumo_images"] = result["suumo_images"]
            enriched_images += 1
            img_count = len(result["suumo_images"])
            print(f"  ✓ {name}: 物件写真{img_count}枚", file=sys.stderr)

        if result.get("floor_plan_images") and not listing.get("floor_plan_images"):
            listings[list_idx]["floor_plan_images"] = result["floor_plan_images"]
            enriched_plans += 1
            plan_count = len(result["floor_plan_images"])
            print(f"  ✓ {name}: 間取り図{plan_count}枚", file=sys.stderr)

        # 進捗表示
        if (idx + 1) % 10 == 0:
            print(
                f"  ...{idx + 1}/{len(targets)}件処理済",
                file=sys.stderr,
            )

    _save_etags(etags)

    # 原子的書き込み
    tmp_path = output_path.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp_path.replace(output_path)

    print(
        f"SUUMO 新築詳細: 物件写真{enriched_images}件, 間取り図{enriched_plans}件に付与",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
