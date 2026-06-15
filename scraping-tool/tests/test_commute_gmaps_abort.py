"""commute_gmaps_enricher の中断判定（サーキットブレーカ）テスト。

GHA データセンター IP が Google Maps にブロックされると全件「取得失敗」となり、
中断条件が無いと core ジョブが 120 分 timeout まで張り付く事象の対策。
should_abort_gmaps が「制限時間超過」「成功0のままの連続失敗（ブロック）」を
正しく検知することを固定する純関数テスト。
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from commute_gmaps_enricher import (  # noqa: E402
    BLOCK_FAILURE_THRESHOLD,
    should_abort_gmaps,
)


def test_no_limit_no_failures_continues() -> None:
    assert should_abort_gmaps(
        deadline=None, now=100.0, total_success=3, consecutive_failures=0
    ) is None


def test_deadline_exceeded_returns_max_time() -> None:
    # now が deadline 以上で打ち切り。
    assert should_abort_gmaps(
        deadline=100.0, now=100.0, total_success=0, consecutive_failures=0
    ) == "max_time"
    assert should_abort_gmaps(
        deadline=100.0, now=150.0, total_success=5, consecutive_failures=0
    ) == "max_time"


def test_before_deadline_continues() -> None:
    assert should_abort_gmaps(
        deadline=100.0, now=99.9, total_success=0, consecutive_failures=1
    ) is None


def test_block_detected_when_zero_success_and_threshold_reached() -> None:
    assert should_abort_gmaps(
        deadline=None,
        now=0.0,
        total_success=0,
        consecutive_failures=BLOCK_FAILURE_THRESHOLD,
    ) == "blocked"


def test_below_threshold_not_blocked() -> None:
    assert should_abort_gmaps(
        deadline=None,
        now=0.0,
        total_success=0,
        consecutive_failures=BLOCK_FAILURE_THRESHOLD - 1,
    ) is None


def test_any_success_disables_block_detection() -> None:
    # 一度でも成功していれば（到達可能）、連続失敗が閾値を超えてもブロック扱いしない。
    assert should_abort_gmaps(
        deadline=None,
        now=0.0,
        total_success=1,
        consecutive_failures=BLOCK_FAILURE_THRESHOLD * 5,
    ) is None


def test_max_time_takes_precedence_over_block() -> None:
    # 時間超過は成功有無に関わらず最優先で打ち切る。
    assert should_abort_gmaps(
        deadline=10.0,
        now=20.0,
        total_success=5,
        consecutive_failures=0,
    ) == "max_time"


def test_custom_threshold() -> None:
    assert should_abort_gmaps(
        deadline=None, now=0.0, total_success=0,
        consecutive_failures=3, block_failure_threshold=3,
    ) == "blocked"
    assert should_abort_gmaps(
        deadline=None, now=0.0, total_success=0,
        consecutive_failures=2, block_failure_threshold=3,
    ) is None
