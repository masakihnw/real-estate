"""Supabase からスクレイピング条件を取得し、config モジュールをパッチする.

scraping_config テーブルの 'default' 行から設定値を読み取り、
config.apply_runtime_overrides() を介して各定数を上書きする。

呼び出し: main.py の最初で load_config_from_supabase() を呼ぶこと。
firestore_config_loader.py の後継。
"""

from __future__ import annotations

from logger import get_logger

logger = get_logger(__name__)


def load_config_from_supabase() -> bool:
    """scraping_config/default から設定を読み込み、config モジュールをパッチする."""
    try:
        from supabase_client import get_client
    except ImportError:
        logger.warning("supabase_client が見つかりません。config.py のデフォルトを使用します。")
        return False

    client = get_client()
    if client is None:
        logger.info("Supabase クライアント未初期化。config.py のデフォルトを使用します。")
        return False

    try:
        resp = client.table("scraping_config").select("config").eq("id", "default").execute()
    except Exception as e:
        logger.error("scraping_config 取得失敗: %s", e)
        return False

    if not resp.data:
        logger.warning("scraping_config に 'default' 行がありません。")
        return False

    data = resp.data[0].get("config", {})
    if not data:
        return False

    import config as config_mod
    applied = config_mod.apply_runtime_overrides(data)

    if applied:
        logger.info("Supabase scraping_config から条件を読み込みました")

    return applied
