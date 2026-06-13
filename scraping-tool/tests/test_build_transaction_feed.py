"""build_transaction_feed.load_station_cache の特性テスト。

geocode_cross_validator はジオコーディング失敗を None でキャッシュする仕様
（再試行防止）。本番 station_cache.json にも None エントリが混入していたため、
load_station_cache が None/壊れたエントリで TypeError を起こしてパイプラインが
落ちる回帰を防ぐ。
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import build_transaction_feed as btf  # noqa: E402


def _write_cache(tmp_path, data) -> str:
    p = tmp_path / "station_cache.json"
    p.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return str(p)


def test_loads_valid_entries(tmp_path, monkeypatch):
    monkeypatch.setattr(
        btf, "STATION_CACHE_PATH", _write_cache(tmp_path, {"品川": [35.62, 139.74]})
    )
    result = btf.load_station_cache()
    assert result == {"品川": (35.62, 139.74)}


def test_skips_none_entries(tmp_path, monkeypatch):
    # ジオコーディング失敗が None でキャッシュされたケース（仕様）
    data = {"品川": [35.62, 139.74], "プラウドシティシリーズ": None}
    monkeypatch.setattr(btf, "STATION_CACHE_PATH", _write_cache(tmp_path, data))
    result = btf.load_station_cache()
    assert "プラウドシティシリーズ" not in result
    assert result == {"品川": (35.62, 139.74)}


def test_skips_malformed_entries(tmp_path, monkeypatch):
    # 座標が欠落／不正な形のエントリも除外する
    data = {"A": [35.0, 139.0], "B": [], "C": [35.0], "D": "x", "E": None}
    monkeypatch.setattr(btf, "STATION_CACHE_PATH", _write_cache(tmp_path, data))
    result = btf.load_station_cache()
    assert result == {"A": (35.0, 139.0)}


def test_missing_file_returns_empty(tmp_path, monkeypatch):
    monkeypatch.setattr(
        btf, "STATION_CACHE_PATH", str(tmp_path / "does_not_exist.json")
    )
    assert btf.load_station_cache() == {}
