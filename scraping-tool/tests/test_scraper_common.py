"""scraper_common のテスト（dump_debug_html）。"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import scraper_common


@pytest.fixture(autouse=True)
def _isolated_dump_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(scraper_common, "DEBUG_DUMP_DIR", tmp_path / "debug_dumps")
    monkeypatch.setattr(scraper_common, "_dump_count", 0)
    yield


class TestSleepWithJitter:
    @pytest.fixture(autouse=True)
    def _no_real_sleep(self, monkeypatch):
        slept: list[float] = []
        monkeypatch.setattr(scraper_common.time, "sleep", lambda s: slept.append(s))
        self.slept = slept
        yield

    def test_returns_zero_for_nonpositive_base(self):
        assert scraper_common.sleep_with_jitter(0) == 0.0
        assert scraper_common.sleep_with_jitter(-1) == 0.0
        assert self.slept == []

    def test_waits_at_least_base(self, monkeypatch):
        """ジッターは上乗せのみ。base を下回らない（エチケット原則）。"""
        monkeypatch.setattr(scraper_common.random, "uniform", lambda a, b: 0.0)
        waited = scraper_common.sleep_with_jitter(3.0)
        assert waited == 3.0
        assert self.slept == [3.0]

    def test_adds_jitter_up_to_ratio(self, monkeypatch):
        """ジッター最大時は base*(1+ratio)。"""
        monkeypatch.setattr(scraper_common.random, "uniform", lambda a, b: b)
        waited = scraper_common.sleep_with_jitter(2.0, jitter_ratio=0.5)
        assert waited == 3.0  # 2.0 + 2.0*0.5
        assert self.slept == [3.0]

    def test_jitter_within_bounds(self, monkeypatch):
        """実乱数でも base 〜 base*(1+ratio) の範囲に収まる。"""
        import random as _r
        monkeypatch.setattr(scraper_common.random, "uniform", _r.uniform)
        for _ in range(50):
            w = scraper_common.sleep_with_jitter(3.0, jitter_ratio=0.3)
            assert 3.0 <= w <= 3.0 * 1.3


class TestDumpDebugHtml:
    def test_saves_html_and_returns_path(self):
        html = "<html><title>認証中</title><body>captcha</body></html>"
        path = scraper_common.dump_debug_html("athome", "chiyoda", html)

        assert path is not None
        assert path.exists()
        assert path.read_text(encoding="utf-8") == html
        assert path.name.startswith("athome_chiyoda_")
        assert path.suffix == ".html"

    def test_extract_title(self):
        assert scraper_common._extract_title("<title>  SUUMO エラー  </title>") == "SUUMO エラー"
        assert scraper_common._extract_title('<TITLE lang="ja">認証中</TITLE>') == "認証中"
        assert scraper_common._extract_title("<html></html>") == "(no title)"

    def test_extract_title_truncates_long_title(self):
        assert scraper_common._extract_title(f"<title>{'あ' * 200}</title>") == "あ" * 80

    def test_dump_cap_per_run(self):
        for i in range(scraper_common._MAX_DUMPS_PER_RUN):
            assert scraper_common.dump_debug_html("athome", f"w{i}", "<html></html>") is not None

        # 上限超過後は保存しない（ログ要約のみ）
        assert scraper_common.dump_debug_html("athome", "w_over", "<html></html>") is None
        saved = list((scraper_common.DEBUG_DUMP_DIR).glob("*.html"))
        assert len(saved) == scraper_common._MAX_DUMPS_PER_RUN

    def test_write_failure_returns_none(self, monkeypatch):
        """保存に失敗してもクラッシュせず None を返す（スクレイプ本体を止めない）。"""
        monkeypatch.setattr(
            Path, "write_text",
            lambda *a, **kw: (_ for _ in ()).throw(OSError("disk full")),
        )
        result = scraper_common.dump_debug_html("athome", "w1", "<html></html>")
        assert result is None
