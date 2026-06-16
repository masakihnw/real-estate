import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import hazard_enricher
from hazard_enricher import (
    _has_any_hazard,
    _resolve_coords,
    enrich_hazard,
    hazard_cache_key,
    load_hazard_cache,
    save_hazard_cache,
)


# ──────────────────────────── hazard_cache_key ────────────────────────────


def test_hazard_cache_key_formats_to_six_decimals():
    assert hazard_cache_key(35.6895, 139.7004) == "35.689500,139.700400"


def test_hazard_cache_key_collapses_coords_within_rounding():
    # 6 桁（≒0.11m）より細かい差は同一キーに集約される
    assert hazard_cache_key(35.6895001, 139.7004001) == hazard_cache_key(
        35.6895002, 139.7004002
    )


def test_hazard_cache_key_distinguishes_distinct_coords():
    assert hazard_cache_key(35.689500, 139.700400) != hazard_cache_key(
        35.689600, 139.700400
    )


# ──────────────────────────── load/save round-trip ────────────────────────────


def test_save_then_load_round_trip(tmp_path):
    path = tmp_path / "cache.json"
    cache = {"35.689500,139.700400": {"flood": True, "fire": 4}}
    save_hazard_cache(cache, path)
    assert path.exists()
    assert load_hazard_cache(path) == cache


def test_load_missing_file_returns_empty(tmp_path):
    assert load_hazard_cache(tmp_path / "nope.json") == {}


def test_load_corrupt_file_returns_empty(tmp_path):
    path = tmp_path / "cache.json"
    path.write_text("{ this is not json", encoding="utf-8")
    assert load_hazard_cache(path) == {}


# ──────────────────────────── _has_any_hazard ────────────────────────────


def test_has_any_hazard_true_on_boolean_flag():
    assert _has_any_hazard({"flood": True}) is True


def test_has_any_hazard_true_on_rank_threshold():
    assert _has_any_hazard({"fire": 3}) is True


def test_has_any_hazard_false_below_threshold():
    assert _has_any_hazard({"fire": 2, "flood": False, "combined": 0}) is False


def test_has_any_hazard_false_on_empty():
    assert _has_any_hazard({}) is False


# ──────────────────────────── _resolve_coords ────────────────────────────


def test_resolve_coords_uses_listing_values():
    assert _resolve_coords({"latitude": 35.1, "longitude": 139.2}, {}) == (35.1, 139.2)


def test_resolve_coords_falls_back_to_geocode_cache():
    listing = {"ss_address": "東京都中央区"}
    geocode = {"東京都中央区": (35.6, 139.7)}
    assert _resolve_coords(listing, geocode) == (35.6, 139.7)


def test_resolve_coords_returns_none_without_coords():
    assert _resolve_coords({"address": "不明住所"}, {}) is None


def test_resolve_coords_casts_string_numbers():
    assert _resolve_coords({"latitude": "35.5", "longitude": "139.5"}, {}) == (35.5, 139.5)


# ──────────────────────────── enrich_hazard with cache ────────────────────────────


def test_enrich_hazard_computes_then_reuses_persisted_cache(tmp_path, monkeypatch):
    """1回目は実計算し、2回目は永続キャッシュから復元して再計算しない。"""
    cache_path = tmp_path / "cache.json"
    calls = []

    def fake_compute(lat, lng):
        calls.append((lat, lng))
        return {"flood": True, "fire": 4}

    monkeypatch.setattr(hazard_enricher, "_compute_hazard", fake_compute)

    listings = [{"latitude": 35.689500, "longitude": 139.700400}]

    # 1回目: 実計算が走る
    enrich_hazard(listings, cache_path=cache_path)
    assert len(calls) == 1
    assert json.loads(listings[0]["hazard_info"]) == {"flood": True, "fire": 4}

    # 2回目: 別プロセス相当（新しい listing dict）。キャッシュ流用で計算は走らない
    calls.clear()
    listings2 = [{"latitude": 35.689500, "longitude": 139.700400}]
    enrich_hazard(listings2, cache_path=cache_path)
    assert calls == []
    assert json.loads(listings2[0]["hazard_info"]) == {"flood": True, "fire": 4}


def test_enrich_hazard_dedupes_same_coord_within_one_run(tmp_path, monkeypatch):
    """同一 run 内で同じ座標が複数物件にあっても実計算は1回だけ。"""
    cache_path = tmp_path / "cache.json"
    calls = []

    def fake_compute(lat, lng):
        calls.append((lat, lng))
        return {"flood": False}

    monkeypatch.setattr(hazard_enricher, "_compute_hazard", fake_compute)

    listings = [
        {"latitude": 35.689500, "longitude": 139.700400},
        {"latitude": 35.689500, "longitude": 139.700400},
        {"latitude": 35.689500, "longitude": 139.700400},
    ]
    enrich_hazard(listings, cache_path=cache_path)
    assert len(calls) == 1
    assert all("hazard_info" in lst for lst in listings)


def test_enrich_hazard_skips_listings_without_coords(tmp_path, monkeypatch):
    cache_path = tmp_path / "cache.json"
    monkeypatch.setattr(hazard_enricher, "_compute_hazard", lambda lat, lng: {"flood": False})

    listings = [{"address": "座標なし住所"}]
    enrich_hazard(listings, cache_path=cache_path)
    assert "hazard_info" not in listings[0]


def test_enrich_hazard_persists_partial_progress_on_exception(tmp_path, monkeypatch):
    """計算が途中で例外を投げても、確定済みの新規座標は永続化される。"""
    cache_path = tmp_path / "cache.json"

    def flaky_compute(lat, lng):
        if lng == 140.0:
            raise RuntimeError("simulated failure")
        return {"flood": False}

    monkeypatch.setattr(hazard_enricher, "_compute_hazard", flaky_compute)

    listings = [
        {"latitude": 35.0, "longitude": 139.0},  # 成功
        {"latitude": 36.0, "longitude": 140.0},  # 例外
    ]
    import pytest

    with pytest.raises(RuntimeError):
        enrich_hazard(listings, cache_path=cache_path)

    persisted = load_hazard_cache(cache_path)
    assert hazard_cache_key(35.0, 139.0) in persisted  # 確定分は残る
    assert hazard_cache_key(36.0, 140.0) not in persisted


def test_enrich_hazard_only_computes_new_coords(tmp_path, monkeypatch):
    """既存座標はキャッシュ流用、新規座標のみ実計算する。"""
    cache_path = tmp_path / "cache.json"
    save_hazard_cache({hazard_cache_key(35.0, 139.0): {"flood": False}}, cache_path)

    calls = []

    def fake_compute(lat, lng):
        calls.append((lat, lng))
        return {"flood": True}

    monkeypatch.setattr(hazard_enricher, "_compute_hazard", fake_compute)

    listings = [
        {"latitude": 35.0, "longitude": 139.0},  # キャッシュ済み
        {"latitude": 36.0, "longitude": 140.0},  # 新規
    ]
    enrich_hazard(listings, cache_path=cache_path)
    assert calls == [(36.0, 140.0)]
    # 永続化され、両座標がキャッシュに載る
    persisted = load_hazard_cache(cache_path)
    assert hazard_cache_key(35.0, 139.0) in persisted
    assert hazard_cache_key(36.0, 140.0) in persisted
