"""detect-delisted ワークフローの入力結線契約テスト（レグレッション網）。

detect-delisted は results/latest.json を入力に SUUMO 詳細を巡回するが、
この latest.json は PII 除去で gitignore 化され repo に存在しない。現行は
Supabase listings_feed のスナップショット（export_supabase_snapshot._flatten_listing
の出力）を入力として供給する。

本テストは実ネットワークを一切叩かず、Supabase 行 →（flatten）→ build_units_cache が
対象 URL を拾えること、という境界契約が壊れていないことを検証する。
過去に latest.json の repo 管理外化でこの結線が黙って切れ、ワークフローが
連続失敗した（対象ファイルなしで exit 1）ため、その再発を防ぐ。
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from scripts.export_supabase_snapshot import _flatten_listing  # noqa: E402


def _suumo_feed_row(**overrides) -> dict:
    """listings_feed の SUUMO 行相当の最小データ。"""
    base = {
        "source": "suumo",
        "url": "https://suumo.jp/ms/chuko/tokyo/sc_x/nc_123/",
        "property_type": "chuko",
        "is_active": True,
        "price_history_json": [{"date": "2026-06-01", "price_man": 5000}],
        "ss_lookup_status": None,  # None フィールドは flatten で除去される想定
    }
    base.update(overrides)
    return base


def test_flatten_preserves_source_and_url():
    """build_units_cache が依存する source / url キーが flatten 後も残る。"""
    flat = _flatten_listing(_suumo_feed_row())

    assert flat["source"] == "suumo"
    assert flat["url"].startswith("https://suumo.jp/")


def test_flatten_drops_none_fields():
    """None フィールドは除去され、後段の get() 判定を壊さない。"""
    flat = _flatten_listing(_suumo_feed_row())

    assert "ss_lookup_status" not in flat


def test_snapshot_feeds_build_units_cache_url_selection():
    """build_units_cache の SUUMO URL 抽出ロジックと同一条件で URL を拾える。

    build_units_cache.main の抽出式:
        [r["url"] for r in rows
         if isinstance(r, dict) and r.get("source") == "suumo" and r.get("url")]
    """
    rows = [
        _flatten_listing(_suumo_feed_row()),
        _flatten_listing(_suumo_feed_row(source="homes", url="https://homes/x")),
        _flatten_listing(_suumo_feed_row(url="https://suumo.jp/ms/chuko/tokyo/nc_999/")),
    ]

    suumo_urls = [
        r["url"]
        for r in rows
        if isinstance(r, dict) and r.get("source") == "suumo" and r.get("url")
    ]

    assert suumo_urls == [
        "https://suumo.jp/ms/chuko/tokyo/sc_x/nc_123/",
        "https://suumo.jp/ms/chuko/tokyo/nc_999/",
    ]
