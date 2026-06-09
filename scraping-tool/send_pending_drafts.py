#!/usr/bin/env python3
"""pending な notification_drafts を Slack 送信する軽量スクリプト。
is_slack_time に依存せず、毎回の finalize で呼ばれる。
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from logger import get_logger
from slack_notify import _send_notification_drafts

logger = get_logger(__name__)


def main() -> None:
    webhook_url = os.environ.get("SLACK_WEBHOOK_URL")
    if not webhook_url:
        return

    try:
        from supabase_client import get_client
        client = get_client()
    except (ImportError, Exception) as e:
        logger.warning("Supabase 接続失敗: %s", e)
        return

    sent, failed = _send_notification_drafts(client, webhook_url)
    if sent > 0:
        logger.info("pending ドラフト %d 件を送信しました", sent)
    if failed > 0:
        logger.error("pending ドラフト %d 件の送信に失敗しました", failed)
        sys.exit(1)


if __name__ == "__main__":
    main()
