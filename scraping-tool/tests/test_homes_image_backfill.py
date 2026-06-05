"""homes_image_backfill.py のユニットテスト。"""
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


def _make_fallback_client(data: list[dict]) -> MagicMock:
    """フォールバッククエリ用のモッククライアントを生成する。"""
    mock_client = MagicMock()
    mock_client.rpc.return_value.execute.side_effect = Exception("no rpc")
    chain = mock_client.table.return_value.select.return_value.eq.return_value.is_.return_value.order.return_value.range.return_value
    chain.execute.return_value = MagicMock(data=data)
    return mock_client


class TestFetchTargets:
    def test_returns_homes_listings_without_images(self):
        from homes_image_backfill import _fetch_targets

        mock_client = _make_fallback_client([
            {"id": 1, "sources_json": [{"source": "homes", "url": "https://www.homes.co.jp/mansion/b-123/", "is_active": True}]},
            {"id": 2, "sources_json": [{"source": "suumo", "url": "https://suumo.jp/ms/123/", "is_active": True}]},
            {"id": 3, "sources_json": [{"source": "homes", "url": "https://www.homes.co.jp/mansion/b-456/", "is_active": True}]},
        ])

        targets = _fetch_targets(mock_client, limit=0)
        assert len(targets) == 2
        assert targets[0]["id"] == 1
        assert targets[1]["id"] == 3

    def test_respects_limit(self):
        from homes_image_backfill import _fetch_targets

        mock_client = _make_fallback_client([
            {"id": i, "sources_json": [{"source": "homes", "url": f"https://www.homes.co.jp/mansion/b-{i}/", "is_active": True}]}
            for i in range(10)
        ])

        targets = _fetch_targets(mock_client, limit=3)
        assert len(targets) == 3

    def test_skips_inactive_homes_sources(self):
        from homes_image_backfill import _fetch_targets

        mock_client = _make_fallback_client([
            {"id": 1, "sources_json": [{"source": "homes", "url": "https://www.homes.co.jp/mansion/b-123/", "is_active": False}]},
        ])

        targets = _fetch_targets(mock_client, limit=0)
        assert len(targets) == 0

    def test_uses_rpc_when_available(self):
        from homes_image_backfill import _fetch_targets

        mock_client = MagicMock()
        mock_client.rpc.return_value.execute.return_value = MagicMock(
            data=[
                {"id": 10, "url": "https://www.homes.co.jp/mansion/b-10/"},
                {"id": 20, "url": "https://www.homes.co.jp/mansion/b-20/"},
            ]
        )

        targets = _fetch_targets(mock_client, limit=0)
        assert len(targets) == 2
        assert targets[0]["id"] == 10
        mock_client.rpc.assert_called_once_with("get_homes_no_images", {})


class TestUpsertImages:
    def test_upserts_both_image_types(self):
        from homes_image_backfill import _upsert_images

        mock_client = MagicMock()
        result = _upsert_images(
            mock_client, 123,
            [{"url": "https://example.com/img.jpg", "label": "外観"}],
            ["https://example.com/fp.jpg"],
            dry_run=False,
        )
        assert result is True
        mock_client.table.assert_called_once_with("enrichments")

    def test_dry_run_skips_db_write(self):
        from homes_image_backfill import _upsert_images

        mock_client = MagicMock()
        result = _upsert_images(
            mock_client, 123,
            [{"url": "https://example.com/img.jpg", "label": "外観"}],
            [],
            dry_run=True,
        )
        assert result is True
        mock_client.table.assert_not_called()

    def test_returns_false_when_no_images(self):
        from homes_image_backfill import _upsert_images

        mock_client = MagicMock()
        result = _upsert_images(mock_client, 123, [], [], dry_run=False)
        assert result is False
