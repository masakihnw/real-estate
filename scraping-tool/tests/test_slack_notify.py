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

from slack_notify import (
    _send_notification_drafts,
    _get_watchlist_price_drops,
    build_watchlist_price_drop_section,
)


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


class TestBuildWatchlistPriceDropSection:
    """build_watchlist_price_drop_section のテスト"""

    def test_empty_drops_returns_empty(self):
        assert build_watchlist_price_drop_section([]) == ""

    def test_liked_property_shows_heart(self):
        drops = [{
            "listing_id": 1,
            "name": "テストマンション",
            "old_price_man": 5000,
            "new_price_man": 4800,
            "change_pct": 4.0,
            "changed_at": "2026-06-09T00:00:00Z",
            "is_liked": True,
            "asset_grade": "B",
        }]
        result = build_watchlist_price_drop_section(drops)
        assert "❤️" in result
        assert "テストマンション" in result
        assert "▼200万円" in result
        assert "-4.0%" in result

    def test_high_rated_property_shows_grade(self):
        drops = [{
            "listing_id": 2,
            "name": "Sランクマンション",
            "old_price_man": 8000,
            "new_price_man": 7500,
            "change_pct": 6.25,
            "changed_at": "2026-06-09T00:00:00Z",
            "is_liked": False,
            "asset_grade": "S",
        }]
        result = build_watchlist_price_drop_section(drops)
        assert "[S]" in result
        assert "❤️" not in result
        assert "▼500万円" in result

    def test_liked_and_high_rated_shows_both(self):
        drops = [{
            "listing_id": 3,
            "name": "両方マンション",
            "old_price_man": 6000,
            "new_price_man": 5700,
            "change_pct": 5.0,
            "changed_at": "2026-06-09T00:00:00Z",
            "is_liked": True,
            "asset_grade": "A",
        }]
        result = build_watchlist_price_drop_section(drops)
        assert "❤️[A]" in result

    def test_sorted_by_change_pct_descending(self):
        drops = [
            {
                "listing_id": 1, "name": "小幅値下げ",
                "old_price_man": 5000, "new_price_man": 4900,
                "change_pct": 2.0, "changed_at": "2026-06-09T00:00:00Z",
                "is_liked": True, "asset_grade": "B",
            },
            {
                "listing_id": 2, "name": "大幅値下げ",
                "old_price_man": 8000, "new_price_man": 7000,
                "change_pct": 12.5, "changed_at": "2026-06-09T00:00:00Z",
                "is_liked": True, "asset_grade": "A",
            },
        ]
        result = build_watchlist_price_drop_section(drops)
        pos_big = result.index("大幅値下げ")
        pos_small = result.index("小幅値下げ")
        assert pos_big < pos_small

    def test_section_header_present(self):
        drops = [{
            "listing_id": 1, "name": "テスト",
            "old_price_man": 5000, "new_price_man": 4800,
            "change_pct": 4.0, "changed_at": "2026-06-09T00:00:00Z",
            "is_liked": True, "asset_grade": "B",
        }]
        result = build_watchlist_price_drop_section(drops)
        assert "💰 注目物件の値下げ" in result
        assert "お気に入り・高評価 S/A 物件" in result


class TestGetWatchlistPriceDrops:
    """_get_watchlist_price_drops のテスト"""

    def _make_supabase_client(
        self,
        rpc_data: list[dict],
        annotations_data: list[dict],
        enrichments_data: list[dict],
        listings_data: list[dict],
    ) -> MagicMock:
        client = MagicMock()

        def rpc_side_effect(name, params=None):
            result = MagicMock()
            if name == "get_significant_price_changes":
                result.execute.return_value = MagicMock(data=rpc_data)
            else:
                result.execute.return_value = MagicMock(data=[])
            return result

        client.rpc.side_effect = rpc_side_effect

        def table_side_effect(name):
            table = MagicMock()
            chain = table.select.return_value
            if name == "user_annotations":
                chain.eq.return_value.execute.return_value = MagicMock(data=annotations_data)
            elif name == "enrichments":
                chain.in_.return_value.execute.return_value = MagicMock(data=enrichments_data)
            elif name == "listings":
                chain.in_.return_value.execute.return_value = MagicMock(data=listings_data)
            return table

        client.table.side_effect = table_side_effect
        return client

    def test_returns_liked_listings(self):
        client = self._make_supabase_client(
            rpc_data=[{
                "listing_id": 10, "name": "お気に入り物件",
                "old_price_man": 5000, "new_price_man": 4800,
                "change_pct": 4.0, "changed_at": "2026-06-09T00:00:00Z",
            }],
            annotations_data=[{"listing_identity_key": "お気に入り物件|東京都"}],
            enrichments_data=[{"listing_id": 10, "asset_grade": "C"}],
            listings_data=[{"id": 10, "identity_key": "お気に入り物件|東京都"}],
        )
        result = _get_watchlist_price_drops(client, "2026-06-08T00:00:00Z")
        assert len(result) == 1
        assert result[0]["is_liked"] is True
        assert result[0]["name"] == "お気に入り物件"

    def test_returns_high_rated_listings(self):
        client = self._make_supabase_client(
            rpc_data=[{
                "listing_id": 20, "name": "Sランク物件",
                "old_price_man": 8000, "new_price_man": 7500,
                "change_pct": 6.25, "changed_at": "2026-06-09T00:00:00Z",
            }],
            annotations_data=[],
            enrichments_data=[{"listing_id": 20, "asset_grade": "S"}],
            listings_data=[{"id": 20, "identity_key": "Sランク物件|東京都"}],
        )
        result = _get_watchlist_price_drops(client, "2026-06-08T00:00:00Z")
        assert len(result) == 1
        assert result[0]["asset_grade"] == "S"
        assert result[0]["is_liked"] is False

    def test_excludes_non_watched_listings(self):
        client = self._make_supabase_client(
            rpc_data=[{
                "listing_id": 30, "name": "普通の物件",
                "old_price_man": 5000, "new_price_man": 4800,
                "change_pct": 4.0, "changed_at": "2026-06-09T00:00:00Z",
            }],
            annotations_data=[],
            enrichments_data=[{"listing_id": 30, "asset_grade": "C"}],
            listings_data=[{"id": 30, "identity_key": "普通の物件|東京都"}],
        )
        result = _get_watchlist_price_drops(client, "2026-06-08T00:00:00Z")
        assert len(result) == 0

    def test_empty_rpc_returns_empty(self):
        client = self._make_supabase_client(
            rpc_data=[], annotations_data=[], enrichments_data=[], listings_data=[],
        )
        result = _get_watchlist_price_drops(client, "2026-06-08T00:00:00Z")
        assert result == []

    def test_rpc_failure_returns_empty(self):
        client = MagicMock()
        client.rpc.side_effect = Exception("connection error")
        result = _get_watchlist_price_drops(client, "2026-06-08T00:00:00Z")
        assert result == []

    def test_rpc_called_with_pct_unit_threshold(self):
        """p_min_drop_pct は %単位（0.1 = 0.1%）で RPC に渡される。

        RPC 側の change_pct / p_min_drop_pct は正の値下げ率（%単位）。
        分数（0.1 = 10%）と誤解して変更しないことを固定するテスト。
        """
        from slack_notify import WATCHLIST_MIN_DROP_PCT

        client = self._make_supabase_client(
            rpc_data=[], annotations_data=[], enrichments_data=[], listings_data=[],
        )
        _get_watchlist_price_drops(client, "2026-06-08T00:00:00Z")

        client.rpc.assert_called_once_with("get_significant_price_changes", {
            "p_since": "2026-06-08T00:00:00Z",
            "p_min_drop_pct": WATCHLIST_MIN_DROP_PCT,
        })
        assert 0 < WATCHLIST_MIN_DROP_PCT < 5.0
