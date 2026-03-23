"""
共通ロガー設定モジュール。

全スクレイピングツールはこのモジュールから get_logger() でロガーを取得する。
環境変数 LOG_LEVEL でログレベルを調整できる（デフォルト: INFO）。
GitHub Actions では stderr に出力され、ログレベル付きでフィルタリング可能。

使い方:
    from logger import get_logger
    logger = get_logger(__name__)
    logger.info("処理開始")
    logger.warning("警告メッセージ")
    logger.error("エラーが発生しました: %s", err)
"""

from __future__ import annotations

import logging
import os
import sys


def _setup_root_logger() -> None:
    """ルートロガーをセットアップする（1回だけ実行）。"""
    root = logging.getLogger("realestate")
    if root.handlers:
        return  # 既にセットアップ済み

    level_name = os.environ.get("LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    root.setLevel(level)

    handler = logging.StreamHandler(sys.stderr)
    handler.setLevel(level)

    # GitHub Actions / ローカル両方で読みやすいフォーマット
    formatter = logging.Formatter(
        fmt="[%(levelname)s] %(name)s: %(message)s",
    )
    handler.setFormatter(formatter)
    root.addHandler(handler)
    # 親ロガー（root）への伝播を無効化してダブルログを防ぐ
    root.propagate = False


def get_logger(name: str = "realestate") -> logging.Logger:
    """
    指定名のロガーを取得する。

    Args:
        name: ロガー名。通常は __name__ を渡す。
              "realestate" 以下の階層名を自動付与する。

    Returns:
        設定済みの logging.Logger インスタンス。
    """
    _setup_root_logger()
    # "realestate" プレフィックスを付与（例: __name__ が "suumo_scraper" → "realestate.suumo_scraper"）
    if not name.startswith("realestate"):
        full_name = f"realestate.{name}"
    else:
        full_name = name
    return logging.getLogger(full_name)
