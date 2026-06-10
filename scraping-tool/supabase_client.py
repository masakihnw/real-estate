"""Supabase クライアント初期化モジュール。

環境変数 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY が設定されている場合のみ
クライアントを返す。未設定時は None を返し、呼び出し側で graceful skip する。
"""

from __future__ import annotations

import os
import logging

logger = logging.getLogger(__name__)

_client = None
_initialized = False

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")


def get_client():
    """Supabase クライアントのシングルトンを返す。未設定時は None。"""
    global _client, _initialized
    if _initialized:
        return _client

    _initialized = True

    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        logger.info("SUPABASE_URL/SERVICE_ROLE_KEY 未設定: Supabase 同期を無効化")
        return None

    try:
        from supabase import create_client
        _client = create_client(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
        logger.info("Supabase クライアント初期化成功: %s", SUPABASE_URL)
    except ImportError:
        logger.warning("supabase パッケージ未インストール: pip install supabase")
    except Exception as e:
        logger.error("Supabase クライアント初期化失敗: %s", e)

    return _client


# identity_key は日本語を含み URL エンコード後1件150B超になるため、
# PostgREST の URL 長制限（~20KB）を超えないようチャンクは20件に抑える
RESOLVE_CHUNK_SIZE = 20


def resolve_listing_ids(client, identity_keys: list[str]) -> dict[str, int]:
    """identity_key のリストを listings.id に解決して dict で返す。

    supabase_sync / enrichment_writer の重複実装を共通化したもの。
    チャンク取得に失敗した場合は1件ずつフォールバックする。
    """
    iks = [ik for ik in dict.fromkeys(identity_keys) if ik]
    ik_to_id: dict[str, int] = {}
    for i in range(0, len(iks), RESOLVE_CHUNK_SIZE):
        chunk = iks[i:i + RESOLVE_CHUNK_SIZE]
        try:
            resp = (client.table("listings")
                    .select("id, identity_key")
                    .in_("identity_key", chunk)
                    .execute())
            for row in (resp.data or []):
                ik_to_id[row["identity_key"]] = row["id"]
        except Exception as e:
            logger.error("[supabase] listing_id 解決エラー (chunk %d): %s", i, e)
            for ik in chunk:
                try:
                    resp = (client.table("listings")
                            .select("id, identity_key")
                            .eq("identity_key", ik)
                            .execute())
                    if resp.data:
                        ik_to_id[resp.data[0]["identity_key"]] = resp.data[0]["id"]
                except Exception as row_err:
                    logger.debug("[supabase] per-row fallback 失敗 (ik=%s): %s", ik[:40], row_err)
    return ik_to_id
