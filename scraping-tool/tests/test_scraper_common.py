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


# ─────────────────────── EmptyParseGuard ───────────────────────
from scraper_common import EmptyParseGuard  # noqa: E402


def test_empty_parse_guard_stops_at_tolerance():
    guard = EmptyParseGuard(2)
    assert guard.record_empty() is False  # 1回目: 続行
    assert guard.consecutive == 1
    assert guard.record_empty() is True   # 2回目: 停止
    assert guard.consecutive == 2


def test_empty_parse_guard_success_resets_and_returns_gap():
    guard = EmptyParseGuard(2)
    assert guard.record_empty() is False
    gap = guard.record_success()
    assert gap == 1          # 途中の空ページ = 異常ギャップとして呼び出し側が記録できる
    assert guard.consecutive == 0
    # リセット後はまた tolerance 回まで許容
    assert guard.record_empty() is False
    assert guard.record_empty() is True


def test_empty_parse_guard_success_without_gap_returns_zero():
    guard = EmptyParseGuard(2)
    assert guard.record_success() == 0


def test_empty_parse_guard_tolerance_one_stops_immediately():
    guard = EmptyParseGuard(1)
    assert guard.record_empty() is True


def test_empty_parse_guard_rejects_invalid_tolerance():
    import pytest
    with pytest.raises(ValueError):
        EmptyParseGuard(0)


# ──────────────── classify_empty_list_page（パース0件の応答分類）────────────────

from scraper_common import classify_empty_list_page  # noqa: E402

_VALID_LIST_HTML = (
    "<html><head><title>中野区の中古マンション購入｜東急リバブル</title></head>"
    "<body>" + ("x" * 6000) + "</body></html>"
)


def test_classify_waf_challenge():
    html = "<html>" + "gokuProps" + "</html>"  # 5000B未満＋WAFマーカー
    assert classify_empty_list_page(html) == "waf_challenge"


def test_classify_blocked_or_changed_for_valid_looking_page():
    # 正常サイズ・正規 title なのにカード0件 → IPブロック/構造変更（断定しない）
    assert classify_empty_list_page(_VALID_LIST_HTML) == "blocked_or_changed"


def test_classify_unexpected_for_small_page():
    assert classify_empty_list_page("<html><body>oops</body></html>") == "unexpected"


def test_classify_unexpected_when_no_title_even_if_large():
    html = "<html><body>" + ("y" * 6000) + "</body></html>"  # title 無し
    assert classify_empty_list_page(html) == "unexpected"


def test_classify_does_not_assert_structure_change_for_blocked():
    # 回帰防止: 正常応答×カード0件を "structure_change" と断定しない
    assert classify_empty_list_page(_VALID_LIST_HTML) != "structure_change"
