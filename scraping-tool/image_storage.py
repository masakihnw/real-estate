"""画像ストレージバックエンドの抽象化（Supabase Storage / Cloudflare R2）。

R2_* 環境変数が揃っている場合は Cloudflare R2 を使い、未設定時は従来どおり
Supabase Storage（listing-images バケット）を使う。URL 判定・オブジェクト名
抽出のヘルパーは upload_floor_plans / GC / 移行スクリプトで共有する。

必要な環境変数（R2 を使う場合）:
  R2_ENDPOINT_URL       https://<account_id>.r2.cloudflarestorage.com
  R2_ACCESS_KEY_ID      R2 API トークンのアクセスキー
  R2_SECRET_ACCESS_KEY  R2 API トークンのシークレット
  R2_BUCKET_NAME        バケット名（デフォルト: listing-images）
  R2_PUBLIC_BASE_URL    公開 URL のベース（例: https://pub-xxxx.r2.dev）
"""

from __future__ import annotations

import os
import threading
from datetime import datetime, timezone
from typing import Optional

from logger import get_logger

logger = get_logger(__name__)

SUPABASE_STORAGE_HOST = "supabase.co/storage"
SUPABASE_BUCKET_NAME = "listing-images"
R2_DEV_HOST_MARKER = ".r2.dev/"

# バケット直下のフォルダ構成（upload_floor_plans.py がこの2つに書き込む）
STORAGE_PREFIXES = ("property_images", "floor_plans")
LIST_PAGE_SIZE = 1000
DELETE_BATCH_SIZE = 100

R2_ENDPOINT_URL = os.environ.get("R2_ENDPOINT_URL", "")
R2_ACCESS_KEY_ID = os.environ.get("R2_ACCESS_KEY_ID", "")
R2_SECRET_ACCESS_KEY = os.environ.get("R2_SECRET_ACCESS_KEY", "")
R2_BUCKET_NAME = os.environ.get("R2_BUCKET_NAME", "listing-images")
R2_PUBLIC_BASE_URL = os.environ.get("R2_PUBLIC_BASE_URL", "").rstrip("/")

_r2_client = None
_r2_lock = threading.Lock()


def r2_configured() -> bool:
    """R2 への接続情報が揃っているか。"""
    return bool(
        R2_ENDPOINT_URL
        and R2_ACCESS_KEY_ID
        and R2_SECRET_ACCESS_KEY
        and R2_PUBLIC_BASE_URL
    )


def get_r2_client():
    """R2 用 boto3 S3 クライアント。boto3 クライアントはスレッドセーフなので共有する。"""
    global _r2_client
    if _r2_client is None:
        with _r2_lock:
            if _r2_client is None:
                import boto3
                from botocore.config import Config

                _r2_client = boto3.client(
                    "s3",
                    endpoint_url=R2_ENDPOINT_URL,
                    aws_access_key_id=R2_ACCESS_KEY_ID,
                    aws_secret_access_key=R2_SECRET_ACCESS_KEY,
                    region_name="auto",
                    config=Config(retries={"max_attempts": 3, "mode": "standard"}),
                )
    return _r2_client


def r2_public_url(blob_path: str) -> str:
    """R2 上のオブジェクトの公開 URL を返す。"""
    return f"{R2_PUBLIC_BASE_URL}/{blob_path}"


def upload_image_r2(blob_path: str, data: bytes, content_type: str) -> str:
    """R2 にアップロードし、公開 URL を返す。"""
    client = get_r2_client()
    client.put_object(
        Bucket=R2_BUCKET_NAME,
        Key=blob_path,
        Body=data,
        ContentType=content_type,
    )
    return r2_public_url(blob_path)


def is_stored_url(url: str) -> bool:
    """自前ストレージ（Supabase Storage / R2）に格納済みの URL か判定。"""
    if not url:
        return False
    if SUPABASE_STORAGE_HOST in url:
        return True
    if R2_PUBLIC_BASE_URL and url.startswith(R2_PUBLIC_BASE_URL + "/"):
        return True
    return R2_DEV_HOST_MARKER in url


def extract_object_name(url: str) -> Optional[str]:
    """ストレージ URL からバケット内のオブジェクト名を取り出す。

    例: https://xxx.supabase.co/storage/v1/object/public/listing-images/property_images/ab.jpg
        -> property_images/ab.jpg
    外部サイト等、自前ストレージ以外の URL は None を返す。
    """
    if not url:
        return None
    name: Optional[str] = None
    supabase_marker = f"/{SUPABASE_BUCKET_NAME}/"
    if SUPABASE_STORAGE_HOST in url and supabase_marker in url:
        name = url.split(supabase_marker, 1)[1]
    elif R2_PUBLIC_BASE_URL and url.startswith(R2_PUBLIC_BASE_URL + "/"):
        name = url[len(R2_PUBLIC_BASE_URL) + 1:]
    elif R2_DEV_HOST_MARKER in url:
        name = url.split(R2_DEV_HOST_MARKER, 1)[1]
    if not name:
        return None
    name = name.split("?", 1)[0].strip("/")
    return name or None


def _parse_timestamp(value) -> Optional[datetime]:
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    return None


def list_supabase_objects(client) -> dict[str, dict]:
    """Supabase Storage の全オブジェクトを {name: {"size", "ts"}} で返す。"""
    bucket = client.storage.from_(SUPABASE_BUCKET_NAME)
    objects: dict[str, dict] = {}
    for prefix in STORAGE_PREFIXES:
        offset = 0
        while True:
            batch = bucket.list(
                path=prefix,
                options={"limit": LIST_PAGE_SIZE, "offset": offset,
                         "sortBy": {"column": "name", "order": "asc"}},
            )
            if not batch:
                break
            for obj in batch:
                name = obj.get("name")
                if not name or obj.get("id") is None:
                    continue  # フォルダプレースホルダはスキップ
                objects[f"{prefix}/{name}"] = {
                    "size": int((obj.get("metadata") or {}).get("size") or 0),
                    "ts": _parse_timestamp(obj.get("created_at")),
                }
            if len(batch) < LIST_PAGE_SIZE:
                break
            offset += LIST_PAGE_SIZE
    return objects


def list_r2_objects() -> dict[str, dict]:
    """R2 の全オブジェクトを {key: {"size", "ts"}} で返す。"""
    client = get_r2_client()
    objects: dict[str, dict] = {}
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=R2_BUCKET_NAME):
        for obj in page.get("Contents", []):
            objects[obj["Key"]] = {
                "size": obj["Size"],
                "ts": _parse_timestamp(obj.get("LastModified")),
            }
    return objects


def delete_supabase_objects(client, names: list[str]) -> int:
    """Supabase Storage からバッチ削除し、削除できた件数を返す。"""
    bucket = client.storage.from_(SUPABASE_BUCKET_NAME)
    deleted = 0
    for i in range(0, len(names), DELETE_BATCH_SIZE):
        batch = names[i:i + DELETE_BATCH_SIZE]
        try:
            bucket.remove(batch)
            deleted += len(batch)
        except Exception as e:
            logger.error("Supabase Storage 削除失敗 (batch %d): %s", i, e)
        if deleted and deleted % 2000 == 0:
            logger.info("  ...%d/%d 件削除済", deleted, len(names))
    return deleted


def delete_r2_objects(names: list[str]) -> int:
    """R2 からバッチ削除し、削除できた件数を返す。"""
    client = get_r2_client()
    deleted = 0
    for i in range(0, len(names), 1000):
        batch = names[i:i + 1000]
        try:
            resp = client.delete_objects(
                Bucket=R2_BUCKET_NAME,
                Delete={"Objects": [{"Key": k} for k in batch], "Quiet": True},
            )
            errors = resp.get("Errors", [])
            deleted += len(batch) - len(errors)
            for err in errors[:5]:
                logger.error("R2 削除失敗: %s (%s)", err.get("Key"), err.get("Message"))
        except Exception as e:
            logger.error("R2 削除失敗 (batch %d): %s", i, e)
    return deleted
