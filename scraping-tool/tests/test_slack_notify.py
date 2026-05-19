"""
slack_notify の _send_notification_drafts フォールバックロジックのテスト。
new_listing_digest が翌日以降も pending なら単独送信する。
"""
from datetime import date, timedelta
from unittest.mock import MagicMock, call, patch

import pytest

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from slack_notify import _send_notification_drafts


def _make_draft(
    draft_id: int,
    ntype: str,
    draft_date: str,
    msg: str = "test message",
) -> dict:
    return {
        "id": draft_id,
        "notification_type": ntype,
        "draft_date": draft_date,
        "message_text": msg,
        "metadata": {},
    }


def _mock_client(drafts: list[dict]) -> MagicMock:
    client = MagicMock()
    rpc_result = MagicMock()
    rpc_result.execute.return_value = MagicMock(data=drafts)

    def rpc_side_effect(name, params=None):
        if name == "get_pending_notification_drafts":
            return rpc_result
        mark_result = MagicMock()
        mark_result.execute.return_value = None
        return mark_result

    client.rpc.side_effect = rpc_side_effect
    return client


class TestSendNotificationDrafts:
    """_send_notification_drafts のフォールバック動作テスト"""

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_skip_daily_brief(self, mock_send):
        today = date.today().isoformat()
        drafts = [_make_draft(1, "daily_brief", today)]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 0
        assert failed == 0
        mock_send.assert_not_called()

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_skip_health_report(self, mock_send):
        today = date.today().isoformat()
        drafts = [_make_draft(1, "health_report", today)]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 0
        mock_send.assert_not_called()

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_new_listing_digest_today_skipped(self, mock_send):
        """当日の new_listing_digest は is_morning 統合を待つためスキップ"""
        today = date.today().isoformat()
        drafts = [_make_draft(1, "new_listing_digest", today, "digest today")]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 0
        mock_send.assert_not_called()

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_new_listing_digest_yesterday_fallback_sent(self, mock_send):
        """前日の new_listing_digest はフォールバック送信される"""
        yesterday = (date.today() - timedelta(days=1)).isoformat()
        drafts = [_make_draft(1, "new_listing_digest", yesterday, "digest yesterday")]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 1
        assert failed == 0
        mock_send.assert_called_once_with("https://example.com/webhook", "digest yesterday")

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_new_listing_digest_3_days_old_fallback_sent(self, mock_send):
        """3日前の new_listing_digest もフォールバック送信される"""
        three_days_ago = (date.today() - timedelta(days=3)).isoformat()
        drafts = [_make_draft(1, "new_listing_digest", three_days_ago, "old digest")]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 1
        mock_send.assert_called_once()

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_price_alert_sent_normally(self, mock_send):
        """price_alert は通常通り送信される"""
        today = date.today().isoformat()
        drafts = [_make_draft(1, "price_alert", today, "price dropped")]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 1
        mock_send.assert_called_once_with("https://example.com/webhook", "price dropped")

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_pipeline_health_report_sent_normally(self, mock_send):
        """pipeline_health_report は SKIP_TYPES に含まれないので送信される"""
        today = date.today().isoformat()
        drafts = [_make_draft(1, "pipeline_health_report", today, "health report")]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 1
        mock_send.assert_called_once()

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=False)
    def test_send_failure_counted(self, mock_send):
        """送信失敗はfailedとしてカウント"""
        today = date.today().isoformat()
        drafts = [_make_draft(1, "price_alert", today, "msg")]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 0
        assert failed == 1

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_empty_message_skipped(self, mock_send):
        """空メッセージはスキップ"""
        today = date.today().isoformat()
        drafts = [_make_draft(1, "price_alert", today, "  ")]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 0
        mock_send.assert_not_called()

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_mixed_drafts(self, mock_send):
        """複数タイプ混在: daily_brief はスキップ、当日 digest はスキップ、前日 digest は送信"""
        today = date.today().isoformat()
        yesterday = (date.today() - timedelta(days=1)).isoformat()
        drafts = [
            _make_draft(1, "daily_brief", today, "brief"),
            _make_draft(2, "new_listing_digest", today, "digest today"),
            _make_draft(3, "new_listing_digest", yesterday, "digest yesterday"),
            _make_draft(4, "price_alert", today, "price alert"),
        ]
        client = _mock_client(drafts)

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 2
        assert failed == 0
        calls = mock_send.call_args_list
        assert any("digest yesterday" in str(c) for c in calls)
        assert any("price alert" in str(c) for c in calls)

    @patch("slack_notify.send_slack_message_chunked_with_retry", return_value=True)
    def test_rpc_failure_returns_zero(self, mock_send):
        """RPC 呼び出し失敗時は (0, 0) を返す"""
        client = MagicMock()
        client.rpc.side_effect = Exception("connection error")

        sent, failed = _send_notification_drafts(client, "https://example.com/webhook")

        assert sent == 0
        assert failed == 0
