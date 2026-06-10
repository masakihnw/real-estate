"""supabase_client.resolve_listing_ids のテスト。"""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from supabase_client import resolve_listing_ids, RESOLVE_CHUNK_SIZE


def _client_returning(rows_by_chunk: list[list[dict]]) -> MagicMock:
    client = MagicMock()
    chain = client.table.return_value.select.return_value.in_.return_value
    chain.execute.side_effect = [MagicMock(data=rows) for rows in rows_by_chunk]
    return client


def test_resolves_ids_in_chunks():
    """チャンクサイズ（PostgREST URL長制限由来の20）ごとに分割して取得する。"""
    iks = [f"ik{i}" for i in range(RESOLVE_CHUNK_SIZE + 5)]
    client = _client_returning([
        [{"identity_key": f"ik{i}", "id": 100 + i} for i in range(RESOLVE_CHUNK_SIZE)],
        [{"identity_key": f"ik{i}", "id": 100 + i}
         for i in range(RESOLVE_CHUNK_SIZE, RESOLVE_CHUNK_SIZE + 5)],
    ])

    result = resolve_listing_ids(client, iks)

    assert len(result) == RESOLVE_CHUNK_SIZE + 5
    assert result["ik0"] == 100
    # 2チャンク = 2回の in_ クエリ
    assert client.table.return_value.select.return_value.in_.call_count == 2


def test_deduplicates_and_skips_empty_keys():
    client = _client_returning([[{"identity_key": "ik1", "id": 1}]])
    result = resolve_listing_ids(client, ["ik1", "ik1", "", "ik1"])
    assert result == {"ik1": 1}
    # 重複・空除去後の1チャンクのみ
    client.table.return_value.select.return_value.in_.assert_called_once_with(
        "identity_key", ["ik1"])


def test_chunk_failure_falls_back_per_row():
    """チャンク取得失敗時は1件ずつフォールバックして可能な分を解決する。"""
    client = MagicMock()
    in_chain = client.table.return_value.select.return_value.in_.return_value
    in_chain.execute.side_effect = Exception("URL too long")
    eq_chain = client.table.return_value.select.return_value.eq.return_value
    eq_chain.execute.side_effect = [
        MagicMock(data=[{"identity_key": "ik1", "id": 1}]),
        MagicMock(data=[]),
    ]

    result = resolve_listing_ids(client, ["ik1", "ik2"])
    assert result == {"ik1": 1}


def test_empty_input_returns_empty():
    client = MagicMock()
    assert resolve_listing_ids(client, []) == {}
    client.table.assert_not_called()
