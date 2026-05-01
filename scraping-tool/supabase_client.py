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

SUPABASE_URL = os.environ.get("SUPABASE_URL", "https://dzhcumdmzskkvusynmyw.supabase.co")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")


def get_client():
    """Supabase クライアントのシングルトンを返す。未設定時は None。"""
    global _client, _initialized
    if _initialized:
        return _client

    _initialized = True

    if not SUPABASE_SERVICE_ROLE_KEY:
        logger.info("SUPABASE_SERVICE_ROLE_KEY 未設定: Supabase 同期を無効化")
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
