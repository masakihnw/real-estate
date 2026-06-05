"""supabase_config_loader のテスト."""

from __future__ import annotations

import importlib
from unittest.mock import MagicMock, patch

import pytest


def test_returns_false_when_client_unavailable():
    with patch("supabase_client.get_client", return_value=None):
        import supabase_config_loader
        importlib.reload(supabase_config_loader)
        assert supabase_config_loader.load_config_from_supabase() is False


def test_returns_false_when_no_data():
    mock_client = MagicMock()
    mock_resp = MagicMock()
    mock_resp.data = []
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value = mock_resp

    with patch("supabase_client.get_client", return_value=mock_client):
        import supabase_config_loader
        importlib.reload(supabase_config_loader)
        assert supabase_config_loader.load_config_from_supabase() is False


def test_applies_config_when_data_exists():
    mock_client = MagicMock()
    mock_resp = MagicMock()
    mock_resp.data = [{"config": {"priceMinMan": 8000, "priceMaxMan": 13000}}]
    mock_client.table.return_value.select.return_value.eq.return_value.execute.return_value = mock_resp

    with patch("supabase_client.get_client", return_value=mock_client):
        import supabase_config_loader
        importlib.reload(supabase_config_loader)

        import config as config_mod
        old_min = config_mod.PRICE_MIN_MAN
        old_max = config_mod.PRICE_MAX_MAN

        result = supabase_config_loader.load_config_from_supabase()

        assert result is True
        assert config_mod.PRICE_MAX_MAN == 13000
        assert config_mod.PRICE_MIN_MAN == 8000

        config_mod.PRICE_MIN_MAN = old_min
        config_mod.PRICE_MAX_MAN = old_max


def test_handles_exception_gracefully():
    mock_client = MagicMock()
    mock_client.table.return_value.select.return_value.eq.return_value.execute.side_effect = Exception("connection error")

    with patch("supabase_client.get_client", return_value=mock_client):
        import supabase_config_loader
        importlib.reload(supabase_config_loader)
        assert supabase_config_loader.load_config_from_supabase() is False
