"""backup_supabase の純粋ロジックのテスト。

Supabase 実接続は行わず、PostgREST クライアントの呼び出しチェーンを模した
フェイククライアントで backup_table / list_tables / run_backup を検証する。
"""
from __future__ import annotations

import gzip
import json
import os
import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts import backup_supabase  # noqa: E402


class _FakeQuery:
    """client.table(t).select("*").range(a, b).execute() チェーンの模倣。"""

    def __init__(self, rows: list[dict]):
        self._rows = rows
        self._slice = (0, len(rows))

    def select(self, *_args, **_kwargs):
        return self

    def range(self, start: int, end: int):
        self._slice = (start, end)
        return self

    def execute(self):
        start, end = self._slice
        # PostgREST の range は両端含む [start, end]
        return types.SimpleNamespace(data=self._rows[start:end + 1])


class _FakeRPC:
    def __init__(self, data):
        self._data = data

    def execute(self):
        return types.SimpleNamespace(data=self._data)


class _FakeClient:
    def __init__(self, tables: dict[str, list[dict]], rpc_data=None, rpc_error=False):
        self._tables = tables
        self._rpc_data = rpc_data
        self._rpc_error = rpc_error

    def table(self, name: str):
        return _FakeQuery(self._tables.get(name, []))

    def rpc(self, name: str, *_a, **_k):
        if self._rpc_error:
            raise RuntimeError("rpc unavailable")
        return _FakeRPC(self._rpc_data)


def _read_jsonl_gz(path: Path) -> list[dict]:
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def test_backup_table_writes_gzipped_jsonl(tmp_path):
    rows = [{"id": 1, "name": "あ"}, {"id": 2, "name": "い"}]
    client = _FakeClient({"listings": rows})

    count = backup_supabase.backup_table(client, "listings", tmp_path)

    assert count == 2
    out = tmp_path / "listings.jsonl.gz"
    assert out.exists()
    assert _read_jsonl_gz(out) == rows


def test_backup_table_empty_is_not_error(tmp_path):
    client = _FakeClient({"users": []})
    count = backup_supabase.backup_table(client, "users", tmp_path)
    assert count == 0
    assert _read_jsonl_gz(tmp_path / "users.jsonl.gz") == []


def test_list_tables_prefers_rpc():
    client = _FakeClient({}, rpc_data=[{"table_name": "listings"}, {"table_name": "enrichments"}])
    assert backup_supabase.list_tables(client) == ["listings", "enrichments"]


def test_list_tables_falls_back_on_rpc_error():
    client = _FakeClient({}, rpc_error=True)
    assert backup_supabase.list_tables(client) == list(backup_supabase.FALLBACK_TABLES)


def test_list_tables_falls_back_on_empty_rpc():
    client = _FakeClient({}, rpc_data=[])
    assert backup_supabase.list_tables(client) == list(backup_supabase.FALLBACK_TABLES)


def test_run_backup_writes_manifest_and_all_tables(tmp_path, monkeypatch):
    tables = {
        "listings": [{"id": 1}],
        "enrichments": [{"listing_id": 1}, {"listing_id": 2}],
    }
    client = _FakeClient(tables, rpc_data=[{"table_name": t} for t in tables])
    monkeypatch.setattr(backup_supabase, "get_client", lambda: client)

    from datetime import datetime
    manifest = backup_supabase.run_backup(tmp_path, now=datetime(2026, 7, 1, 4, 0, 0))

    assert manifest["table_count"] == 2
    assert manifest["total_rows"] == 3
    assert manifest["tables"] == {"listings": 1, "enrichments": 2}

    backup_dir = tmp_path / "supabase_backup_20260701_040000"
    assert (backup_dir / "manifest.json").exists()
    assert (backup_dir / "listings.jsonl.gz").exists()
    assert (backup_dir / "enrichments.jsonl.gz").exists()


def test_run_backup_records_table_error_and_reports(tmp_path, monkeypatch):
    class _BoomClient(_FakeClient):
        def table(self, name):
            if name == "boom":
                raise RuntimeError("boom failed")
            return super().table(name)

    client = _BoomClient({"ok": [{"id": 1}]},
                         rpc_data=[{"table_name": "ok"}, {"table_name": "boom"}])
    monkeypatch.setattr(backup_supabase, "get_client", lambda: client)

    from datetime import datetime
    manifest = backup_supabase.run_backup(tmp_path, now=datetime(2026, 7, 1, 4, 0, 0))

    assert manifest["tables"]["ok"] == 1
    assert isinstance(manifest["tables"]["boom"], str)
    assert manifest["tables"]["boom"].startswith("ERROR:")


def test_run_backup_exits_without_client(tmp_path, monkeypatch):
    monkeypatch.setattr(backup_supabase, "get_client", lambda: None)
    with pytest.raises(SystemExit):
        backup_supabase.run_backup(tmp_path)
