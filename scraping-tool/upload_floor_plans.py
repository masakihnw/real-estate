#!/usr/bin/env python3
"""
間取り図画像を Firebase Storage にアップロードし、listings JSON 内の URL を置き換える。

スクレイピングで取得した SUUMO/HOME'S の画像 URL を Firebase Storage に保存することで、
物件が掲載終了した後も間取り図を表示可能にする。

設計:
  - 元 URL の SHA256 ハッシュをファイル名に使い、同一画像の重複アップロードを回避
  - マニフェスト（data/floor_plan_storage_manifest.json）で元 URL → Firebase URL のマッピングを保持
  - FIREBASE_SERVICE_ACCOUNT 環境変数が未設定の場合はスキップ（ローカル開発時）
  - ThreadPoolExecutor による並列ダウンロード+アップロードで高速化
  - --max-time で最大実行時間を指定し、超過時は未処理分をスキップ

使い方:
  python upload_floor_plans.py --input results/latest.json --output results/latest.json
  python upload_floor_plans.py --input results/latest.json --output results/latest.json --max-time 20
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Optional
from urllib.parse import quote, urlparse

import requests

STORAGE_BUCKET = "real-estate-app-5b869.firebasestorage.app"

ROOT = Path(__file__).resolve().parent
MANIFEST_DIR = ROOT / "data"
MANIFEST_PATH = MANIFEST_DIR / "floor_plan_storage_manifest.json"

FIREBASE_STORAGE_HOST = "firebasestorage.googleapis.com"

DOWNLOAD_TIMEOUT_SEC = 30
MIN_IMAGE_BYTES = 500
MAX_WORKERS = 8

_thread_local = threading.local()


def _url_to_hash(url: str) -> str:
    """URL から 16 文字のハッシュを生成。"""
    return hashlib.sha256(url.encode("utf-8")).hexdigest()[:16]


def _load_manifest() -> dict[str, str]:
    """マニフェスト（元URL → Firebase URL のマッピング）を読み込む。"""
    if not MANIFEST_PATH.exists():
        return {}
    try:
        with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def _save_manifest(manifest: dict[str, str]) -> None:
    """マニフェストを保存する。"""
    MANIFEST_DIR.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)


def _detect_content_type(url: str, response_content_type: str = "") -> str:
    """URL またはレスポンスヘッダからコンテンツタイプを推定。"""
    ct = response_content_type.lower().split(";")[0].strip()
    if ct in ("image/jpeg", "image/png", "image/gif", "image/webp"):
        return ct

    path = urlparse(url).path.lower()
    if ".png" in path:
        return "image/png"
    if ".gif" in path:
        return "image/gif"
    if ".webp" in path:
        return "image/webp"

    return "image/jpeg"


def _content_type_to_ext(content_type: str) -> str:
    """コンテンツタイプからファイル拡張子を取得。"""
    ext_map = {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/gif": ".gif",
        "image/webp": ".webp",
    }
    return ext_map.get(content_type, ".jpg")


def _init_firebase():
    """Firebase Admin SDK を初期化し、Storage bucket を返す。"""
    json_str = os.environ.get("FIREBASE_SERVICE_ACCOUNT")
    if not json_str or not json_str.strip():
        print(
            "FIREBASE_SERVICE_ACCOUNT が未設定のためスキップ",
            file=sys.stderr,
        )
        return None

    try:
        import firebase_admin
        from firebase_admin import credentials, storage
    except ImportError:
        print("firebase-admin がインストールされていません", file=sys.stderr)
        return None

    try:
        cred_dict = json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"FIREBASE_SERVICE_ACCOUNT の JSON パースに失敗: {e}", file=sys.stderr)
        return None

    try:
        try:
            app = firebase_admin.get_app()
        except ValueError:
            cred = credentials.Certificate(cred_dict)
            app = firebase_admin.initialize_app(cred, {"storageBucket": STORAGE_BUCKET})
        return storage.bucket(name=STORAGE_BUCKET, app=app)
    except Exception as e:
        print(f"Firebase Storage 初期化失敗: {e}", file=sys.stderr)
        return None


def _create_session() -> requests.Session:
    """画像ダウンロード用のセッションを作成。"""
    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/120.0.0.0 Safari/537.36"
            ),
            "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
        }
    )
    return session


def _get_thread_session() -> requests.Session:
    """スレッドローカルな HTTP セッションを取得（スレッドセーフ）。"""
    if not hasattr(_thread_local, "session"):
        _thread_local.session = _create_session()
    return _thread_local.session


def download_image(
    session: requests.Session, url: str
) -> Optional[tuple[bytes, str]]:
    """画像をダウンロードし、(data, content_type) を返す。失敗時は None。"""
    try:
        r = session.get(url, timeout=DOWNLOAD_TIMEOUT_SEC)
        r.raise_for_status()

        content_type = _detect_content_type(url, r.headers.get("Content-Type", ""))
        data = r.content

        if len(data) < MIN_IMAGE_BYTES:
            return None

        return data, content_type
    except Exception:
        return None


def upload_to_storage(bucket, blob_path: str, data: bytes, content_type: str) -> str:
    """Firebase Storage にアップロードし、ダウンロード URL を返す。"""
    blob = bucket.blob(blob_path)
    blob.upload_from_string(data, content_type=content_type)

    token = str(uuid.uuid4())
    blob.metadata = {"firebaseStorageDownloadTokens": token}
    blob.patch()

    download_url = (
        f"https://firebasestorage.googleapis.com/v0/b/{bucket.name}"
        f"/o/{quote(blob_path, safe='')}?alt=media&token={token}"
    )
    return download_url


def _collect_urls(listings: list[dict]) -> dict[str, str]:
    """listings から処理対象の全ユニーク URL を収集。

    Returns: {original_url: storage_dir}
    """
    urls: dict[str, str] = {}
    for listing in listings:
        if not isinstance(listing, dict):
            continue
        for url in listing.get("floor_plan_images") or []:
            if url and isinstance(url, str) and url not in urls:
                urls[url] = "floor_plans"
        for img in listing.get("suumo_images") or []:
            if isinstance(img, dict) and isinstance(img.get("url"), str):
                url = img["url"]
                if url and url not in urls:
                    urls[url] = "property_images"
    return urls


def _parallel_upload(
    bucket,
    urls_to_upload: dict[str, str],
    stats: dict[str, int],
    deadline: float | None,
) -> dict[str, str]:
    """URL を並列にダウンロード+アップロード。

    Returns: {original_url: firebase_url}
    """
    if not urls_to_upload:
        return {}

    results: dict[str, str] = {}
    lock = threading.Lock()
    total = len(urls_to_upload)
    processed = 0

    print(
        f"  新規アップロード対象: {total}件 ({MAX_WORKERS}並列)",
        file=sys.stderr,
    )

    def worker(url: str, storage_dir: str) -> tuple[str, str | None, str]:
        if deadline and time.time() > deadline:
            return url, None, "timeout"

        session = _get_thread_session()
        dl = download_image(session, url)
        if dl is None:
            return url, None, "failed"

        data, content_type = dl
        ext = _content_type_to_ext(content_type)
        blob_path = f"{storage_dir}/{_url_to_hash(url)}{ext}"

        try:
            firebase_url = upload_to_storage(bucket, blob_path, data, content_type)
            return url, firebase_url, "uploaded"
        except Exception as e:
            print(f"  アップロード失敗: {e}", file=sys.stderr)
            return url, None, "failed"

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_map = {
            executor.submit(worker, url, sdir): url
            for url, sdir in urls_to_upload.items()
        }

        for future in concurrent.futures.as_completed(future_map):
            try:
                url, firebase_url, status = future.result()
            except Exception:
                stats["failed"] += 1
                processed += 1
                continue

            stats[status] += 1
            if firebase_url:
                with lock:
                    results[url] = firebase_url
            processed += 1
            if processed % 50 == 0:
                remaining = ""
                if deadline:
                    remaining = f" (残り{int(deadline - time.time())}秒)"
                print(
                    f"  ...{processed}/{total}件処理済{remaining}",
                    file=sys.stderr,
                )

    return results


def _apply_urls(listings: list[dict], manifest: dict[str, str]) -> None:
    """manifest のマッピングを使って listings 内の画像 URL を Firebase Storage URL に置換。"""
    for listing in listings:
        if not isinstance(listing, dict):
            continue

        images = listing.get("floor_plan_images")
        if images and isinstance(images, list):
            listing["floor_plan_images"] = [
                manifest.get(url, url)
                if isinstance(url, str) and FIREBASE_STORAGE_HOST not in url
                else url
                for url in images
            ]

        suumo = listing.get("suumo_images")
        if suumo and isinstance(suumo, list):
            new_suumo: list[dict[str, str]] = []
            for img in suumo:
                if not isinstance(img, dict) or "url" not in img:
                    continue
                orig = img["url"]
                new_url = (
                    manifest.get(orig, orig)
                    if isinstance(orig, str) and FIREBASE_STORAGE_HOST not in orig
                    else orig
                )
                new_suumo.append({"url": new_url, "label": img.get("label", "")})
            listing["suumo_images"] = new_suumo


def main() -> None:
    parser = argparse.ArgumentParser(
        description="間取り図画像を Firebase Storage にアップロード"
    )
    parser.add_argument("--input", required=True, help="入力 JSON ファイル")
    parser.add_argument("--output", required=True, help="出力 JSON ファイル")
    parser.add_argument(
        "--max-time",
        type=int,
        default=0,
        help="最大実行時間（分）。0=無制限",
    )
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

    max_time_sec = args.max_time * 60 if args.max_time > 0 else None
    deadline = time.time() + max_time_sec if max_time_sec else None

    bucket = _init_firebase()
    if bucket is None:
        print(
            "Firebase Storage が利用できないため、URL の置き換えをスキップします",
            file=sys.stderr,
        )
        sys.exit(0)

    manifest = _load_manifest()

    all_urls = _collect_urls(listings)

    stats = {"uploaded": 0, "cached": 0, "failed": 0, "skipped": 0, "timeout": 0}
    to_upload: dict[str, str] = {}
    for url, storage_dir in all_urls.items():
        if FIREBASE_STORAGE_HOST in url:
            stats["skipped"] += 1
        elif url in manifest:
            stats["cached"] += 1
        else:
            to_upload[url] = storage_dir

    total = len(all_urls)
    print(
        f"画像 URL: 全{total}件 "
        f"(新規{len(to_upload)}, キャッシュ{stats['cached']}, "
        f"既存Storage{stats['skipped']})",
        file=sys.stderr,
    )

    new_mappings = _parallel_upload(bucket, to_upload, stats, deadline)
    manifest.update(new_mappings)

    _apply_urls(listings, manifest)

    _save_manifest(manifest)

    tmp = output_path.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp.replace(output_path)

    print(
        f"Storage アップロード完了: "
        f"新規{stats['uploaded']}, キャッシュ{stats['cached']}, "
        f"既存Storage{stats['skipped']}, 失敗{stats['failed']}, "
        f"タイムアウト{stats['timeout']}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
