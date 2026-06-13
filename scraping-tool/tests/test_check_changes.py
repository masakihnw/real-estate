"""check_changes.py の exit code 仕様の特性テスト（refactor Phase 1 安全網）。

update_listings.sh が「変更時のみレポート・通知」する判定に使うため、
exit code の意味（0=変更あり, 1=変更なし, 2=入力エラー）を固定する。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

SCRAPING_ROOT = Path(__file__).resolve().parents[1]


def _listing(**overrides) -> dict:
    base = {
        "name": "パークタワー晴海",
        "layout": "3LDK",
        "area_m2": 70.5,
        "price_man": 9800,
        "address": "東京都中央区晴海2丁目3-1",
        "built_year": 2019,
        "walk_min": 5,
        "station_name": "勝どき",
        "floor_position": 10,
        "source": "suumo",
        "url": "https://example.com/suumo/1",
    }
    base.update(overrides)
    return base


def _run(current_path: Path | str, previous_path: Path | str) -> int:
    proc = subprocess.run(
        [sys.executable, "check_changes.py", str(current_path), str(previous_path)],
        cwd=SCRAPING_ROOT,
        capture_output=True,
        text=True,
        env={**os.environ, "LOG_LEVEL": "ERROR"},
        timeout=60,
    )
    return proc.returncode


def _write(path: Path, data) -> Path:
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return path


def test_exit0_when_new_listing(tmp_path):
    prev = _write(tmp_path / "prev.json", [_listing()])
    curr = _write(
        tmp_path / "curr.json",
        [_listing(), _listing(name="別マンション", url="https://example.com/suumo/2")],
    )
    assert _run(curr, prev) == 0


def test_exit0_when_listing_removed(tmp_path):
    prev = _write(
        tmp_path / "prev.json",
        [_listing(), _listing(name="別マンション", url="https://example.com/suumo/2")],
    )
    curr = _write(tmp_path / "curr.json", [_listing()])
    assert _run(curr, prev) == 0


def test_exit0_when_price_changed(tmp_path):
    """identity_key は価格を含まないため、価格変動は updated として変更扱いになる。"""
    prev = _write(tmp_path / "prev.json", [_listing(price_man=9800)])
    curr = _write(tmp_path / "curr.json", [_listing(price_man=9500)])
    assert _run(curr, prev) == 0


def test_exit1_when_no_changes(tmp_path):
    prev = _write(tmp_path / "prev.json", [_listing()])
    curr = _write(tmp_path / "curr.json", [_listing()])
    assert _run(curr, prev) == 1


def test_exit2_when_current_missing(tmp_path):
    prev = _write(tmp_path / "prev.json", [_listing()])
    assert _run(tmp_path / "nonexistent.json", prev) == 2


def test_exit0_when_previous_missing(tmp_path):
    """previous が無い（初回実行）は変更ありとして続行する。"""
    curr = _write(tmp_path / "curr.json", [_listing()])
    assert _run(curr, tmp_path / "nonexistent.json") == 0


def test_exit0_when_previous_corrupt(tmp_path):
    """previous が壊れている場合はフェイルオープン（変更あり扱い）。"""
    curr = _write(tmp_path / "curr.json", [_listing()])
    broken = tmp_path / "prev.json"
    broken.write_text("{not valid json", encoding="utf-8")
    assert _run(curr, broken) == 0


def test_exit2_when_current_corrupt(tmp_path):
    prev = _write(tmp_path / "prev.json", [_listing()])
    broken = tmp_path / "curr.json"
    broken.write_text("{not valid json", encoding="utf-8")
    assert _run(broken, prev) == 2


def test_exit2_when_wrong_argc():
    proc = subprocess.run(
        [sys.executable, "check_changes.py"],
        cwd=SCRAPING_ROOT,
        capture_output=True,
        text=True,
        env={**os.environ, "LOG_LEVEL": "ERROR"},
        timeout=60,
    )
    assert proc.returncode == 2
