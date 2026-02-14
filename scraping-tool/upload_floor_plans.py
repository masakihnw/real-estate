#!/usr/bin/env python3
"""
間取り図画像を Firebase Storage にアップロードし、listings JSON 内の URL を置き換える。

スクレイピングで取得した SUUMO/HOME'S の画像 URL を Firebase Storage に保存することで、
物件が掲載終了した後も間取り図を表示可能にする。

設計:
  - 元 URL の SHA256 ハッシュをファイル名に使い、同一画像の重複アップロードを回避
  - マニフェスト（data/floor_plan_storage_manifest.json）で元 URL → Firebase URL のマッピングを保持
  - FIREBASE_SERVICE_ACCOUNT 環境変数が未設定の場合はスキップ（ローカル開発時）

使い方:
  python upload_floor_plans.py --input results/latest.json --output results/latest.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
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

# Firebase Storage URL のプレフィックス（アップロード済み判定用）
FIREBASE_STORAGE_HOST = "firebasestorage.googleapis.com"

# 画像ダウンロードの設定
DOWNLOAD_TIMEOUT_SEC = 30
MIN_IMAGE_BYTES = 500  # これより小さいファイルはプレースホルダーとみなす
UPLOAD_DELAY_SEC = 0.1  # Firebase Storage へのアップロード間隔


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
    # レスポンスヘッダの Content-Type を優先
    ct = response_content_type.lower().split(";")[0].strip()
    if ct in ("image/jpeg", "image/png", "image/gif", "image/webp"):
        return ct

    # URL パスから推定
    path = urlparse(url).path.lower()
    if ".png" in path:
        return "image/png"
    if ".gif" in path:
        return "image/gif"
    if ".webp" in path:
        return "image/webp"

    # デフォルト: JPEG（不動産画像は大半が JPEG）
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
            # 既存の app に storageBucket が設定されていない場合がある
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
            print(
                f"  スキップ（{len(data)}B、プレースホルダーの可能性）: {url[:80]}",
                file=sys.stderr,
            )
            return None

        return data, content_type
    except Exception as e:
        print(f"  ダウンロード失敗: {url[:80]}... ({e})", file=sys.stderr)
        return None


def upload_to_storage(bucket, blob_path: str, data: bytes, content_type: str) -> str:
    """Firebase Storage にアップロードし、ダウンロード URL を返す。

    ダウンロード URL にはトークンが含まれるため、Firebase Auth なしでアクセス可能。
    iOS の AsyncImage からそのまま読み込める。
    """
    blob = bucket.blob(blob_path)

    # アップロード
    blob.upload_from_string(data, content_type=content_type)

    # ダウンロードトークンを生成（認証不要の URL を作るため）
    token = str(uuid.uuid4())
    blob.metadata = {"firebaseStorageDownloadTokens": token}
    blob.patch()

    # ダウンロード URL を構築
    download_url = (
        f"https://firebasestorage.googleapis.com/v0/b/{bucket.name}"
        f"/o/{quote(blob_path, safe='')}?alt=media&token={token}"
    )
    return download_url


def process_listings(listings: list[dict], bucket, manifest: dict[str, str]) -> dict:
    """listings 内の floor_plan_images URL を Firebase Storage URL に置き換える。

    Returns:
        統計情報の辞書 {"uploaded": int, "cached": int, "failed": int, "skipped": int}
    """
    session = _create_session()
    stats = {"uploaded": 0, "cached": 0, "failed": 0, "skipped": 0}

    # 対象物件を集計
    target_count = sum(
        1
        for r in listings
        if isinstance(r, dict) and r.get("floor_plan_images")
    )
    if target_count == 0:
        print("間取り図画像を持つ物件はありません", file=sys.stderr)
        return stats

    print(
        f"間取り図 Storage アップロード: {target_count}件の物件を処理します",
        file=sys.stderr,
    )

    processed = 0
    for listing in listings:
        images = listing.get("floor_plan_images")
        if not images or not isinstance(images, list):
            continue

        new_urls: list[str] = []
        for original_url in images:
            # 既に Firebase Storage URL の場合はスキップ
            if FIREBASE_STORAGE_HOST in original_url:
                new_urls.append(original_url)
                stats["skipped"] += 1
                continue

            # マニフェストにキャッシュがある場合
            if original_url in manifest:
                new_urls.append(manifest[original_url])
                stats["cached"] += 1
                continue

            # 画像をダウンロード
            result = download_image(session, original_url)
            if result is None:
                # ダウンロード失敗時は元の URL を維持
                new_urls.append(original_url)
                stats["failed"] += 1
                continue

            data, content_type = result
            ext = _content_type_to_ext(content_type)
            url_hash = _url_to_hash(original_url)
            blob_path = f"floor_plans/{url_hash}{ext}"

            try:
                firebase_url = upload_to_storage(bucket, blob_path, data, content_type)
                new_urls.append(firebase_url)
                manifest[original_url] = firebase_url
                stats["uploaded"] += 1
            except Exception as e:
                print(f"  アップロード失敗: {e}", file=sys.stderr)
                new_urls.append(original_url)
                stats["failed"] += 1
                continue

            # レート制限回避
            time.sleep(UPLOAD_DELAY_SEC)

        listing["floor_plan_images"] = new_urls
        processed += 1

        # 進捗表示
        if processed % 20 == 0:
            print(f"  ...{processed}/{target_count}件処理済", file=sys.stderr)

    return stats


def main() -> None:
    parser = argparse.ArgumentParser(
        description="間取り図画像を Firebase Storage にアップロード"
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

    # Firebase 初期化
    bucket = _init_firebase()
    if bucket is None:
        print(
            "Firebase Storage が利用できないため、URL の置き換えをスキップします",
            file=sys.stderr,
        )
        sys.exit(0)

    # マニフェスト読み込み
    manifest = _load_manifest()

    # 処理実行
    stats = process_listings(listings, bucket, manifest)

    # マニフェスト保存
    _save_manifest(manifest)

    # 原子的書き込み
    tmp = output_path.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)
    tmp.replace(output_path)

    print(
        f"間取り図 Storage: "
        f"新規アップロード {stats['uploaded']}件, "
        f"マニフェストキャッシュ {stats['cached']}件, "
        f"既存Storage {stats['skipped']}件, "
        f"失敗 {stats['failed']}件",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
