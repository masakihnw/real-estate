"""mansion_review_scraper の検索・キャッシュ判定テスト。

非200応答（bot判定/レート制限/障害）を「該当なし」として14日キャッシュし、
弾かれた物件が2週間再検索されなくなる誤判定の修正を検証する。
"""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
import requests

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import mansion_review_scraper as mrs


class _FakeResp:
    def __init__(self, status_code=200, json_data=None, raise_json=False):
        self.status_code = status_code
        self._json = json_data if json_data is not None else {}
        self._raise_json = raise_json

    def json(self):
        if self._raise_json:
            raise ValueError("not json")
        return self._json


def _session_returning(resp):
    return SimpleNamespace(get=lambda *a, **kw: resp)


class TestSearchBuilding:
    def test_found_returns_url(self):
        session = _session_returning(_FakeResp(json_data={"list": [{"id": "12345"}]}))
        url = mrs.search_building(session, "テストマンション")
        assert url and url.endswith("/mansion/12345.html")

    def test_genuinely_not_found_returns_none(self):
        """API は正常応答だが候補ゼロ = 真の該当なし。"""
        session = _session_returning(_FakeResp(json_data={"list": []}))
        assert mrs.search_building(session, "存在しない物件") is None

    def test_non_200_raises_unavailable(self):
        """403/429/5xx は該当なしと区別して SearchUnavailable を送出。"""
        for code in (403, 429, 500, 503):
            session = _session_returning(_FakeResp(status_code=code))
            with pytest.raises(mrs.SearchUnavailable):
                mrs.search_building(session, "ブロックされた物件")

    def test_json_parse_failure_raises_unavailable(self):
        """チャレンジページ等でJSON解析に失敗したら取得不能扱い。"""
        session = _session_returning(_FakeResp(raise_json=True))
        with pytest.raises(mrs.SearchUnavailable):
            mrs.search_building(session, "壊れた応答")

    def test_connection_error_propagates(self):
        def _boom(*a, **kw):
            raise requests.ConnectionError("reset")
        with pytest.raises(requests.ConnectionError):
            mrs.search_building(SimpleNamespace(get=_boom), "切断")


class TestEnrichSingleCaching:
    def test_unavailable_is_not_cached_as_not_found(self, monkeypatch):
        """非200で弾かれた物件は {"data": None} としてキャッシュされない（再試行可能）。"""
        monkeypatch.setattr(mrs.time, "sleep", lambda s: None)
        monkeypatch.setattr(
            mrs, "search_building",
            lambda session, name: (_ for _ in ()).throw(mrs.SearchUnavailable("HTTP 429")),
        )
        cache: dict = {}
        with pytest.raises(mrs.SearchUnavailable):
            mrs.enrich_single(None, "ブロックされた物件", cache)
        assert cache == {}, "取得失敗が該当なしとしてキャッシュされている"

    def test_genuine_not_found_is_cached(self, monkeypatch):
        """真の該当なしは {"data": None} でキャッシュ（無駄な再検索を防ぐ）。"""
        monkeypatch.setattr(mrs.time, "sleep", lambda s: None)
        monkeypatch.setattr(mrs, "search_building", lambda session, name: None)
        cache: dict = {}
        result = mrs.enrich_single(None, "存在しない物件", cache)
        assert result is None
        assert len(cache) >= 1
        assert all(v.get("data") is None for v in cache.values())
