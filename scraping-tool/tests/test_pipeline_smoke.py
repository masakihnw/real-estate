"""パイプライン結線スモークテスト（PR時レグレッション網）。

個別ユニットテストは各ステージの内部仕様を固定するが、ステージ間の
「フィールド受け渡し契約」が壊れるデグレ（例: dedupe が落としたキーを
report が参照して落ちる、name 正規化の戻り値型変更で後段が壊れる等）は
取りこぼす。本テストは実ネットワーク・Claude API を一切叩かず、fixture の
生データを

    clean_listing_name → dedupe_listings → generate_markdown

の順に通し、各境界が結線されたまま壊れていないことを検証する。
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from generate_report import generate_markdown  # noqa: E402
from main import dedupe_listings  # noqa: E402
from report_utils import clean_listing_name  # noqa: E402


def _raw_listing(**overrides) -> dict:
    """main.py の各スクレイパーが返す生 row 相当の最小データ。"""
    base = {
        "name": "パークタワー晴海",
        "layout": "3LDK",
        "area_m2": 70.5,
        "price_man": 9800,
        "address": "東京都中央区晴海2丁目3-1",
        "built_year": 2019,
        "walk_min": 5,
        "station_line": "都営大江戸線「勝どき」徒歩5分",
        "floor_position": 10,
        "floor_total": 48,
        "total_units": 1084,
        "source": "suumo",
        "url": "https://example.com/suumo/1",
        "listing_score": 70,
        "images": ["https://img.example.com/a.jpg"],
    }
    base.update(overrides)
    return base


def _run_pipeline(raw_rows: list[dict]) -> tuple[list[dict], str]:
    """main.py の前処理（名前正規化 → dedupe）を再現し、レポートまで通す。"""
    rows = [dict(r) for r in raw_rows]  # 入力を破壊しない
    for row in rows:
        if row.get("name"):
            cleaned = clean_listing_name(row["name"])
            row["name"] = cleaned if cleaned else "（不明）"
    deduped = dedupe_listings(rows)
    md = generate_markdown(deduped)
    return deduped, md


def test_pipeline_renders_report_from_scraped_rows():
    """単一物件が dedupe→report を通り、レポート本文に現れる。"""
    deduped, md = _run_pipeline([_raw_listing()])

    assert len(deduped) == 1
    assert "中古マンション物件一覧レポート" in md
    assert "パークタワー晴海" in md
    assert "対象件数**: 1件（資産性B以上 / 全1件中）" in md


def test_cross_source_duplicates_merge_then_render():
    """別ソースの同一物件が dedupe で1件に集約され、レポートも1件で出る。

    dedupe→report のフィールド契約が壊れると、ここで件数ズレか例外になる。
    """
    suumo = _raw_listing(source="suumo", url="https://example.com/suumo/1")
    homes = _raw_listing(source="homes", url="https://example.com/homes/1")

    deduped, md = _run_pipeline([suumo, homes])

    assert len(deduped) == 1, "同一物件は1件に集約されるべき"
    assert deduped[0].get("duplicate_count") == 2
    assert "対象件数**: 1件" in md


def test_low_score_listing_filtered_through_pipeline():
    """資産性B未満（score<50）はパイプライン全体を通すとレポートから消える。"""
    high = _raw_listing(listing_score=70, url="https://example.com/suumo/1")
    low = _raw_listing(
        name="低スコアマンション",
        listing_score=30,
        url="https://example.com/suumo/2",
    )

    deduped, md = _run_pipeline([high, low])

    assert len(deduped) == 2, "dedupe は score に関わらず両方残す"
    assert "低スコアマンション" not in md
    assert "対象件数**: 1件（資産性B以上 / 全2件中）" in md


def test_noisy_name_normalized_before_report():
    """「新築マンション」prefix 等のノイズが除去された名前でレポートに出る。"""
    noisy = _raw_listing(name="新築マンション　パークタワー晴海　閲覧済")

    _, md = _run_pipeline([noisy])

    assert "パークタワー晴海" in md
    assert "新築マンション" not in md
    assert "閲覧済" not in md


def test_empty_input_produces_valid_report():
    """0件入力でも例外を出さず、件数0のレポートを生成する（botブロック等の終端）。"""
    deduped, md = _run_pipeline([])

    assert deduped == []
    assert "対象件数**: 0件（資産性B以上 / 全0件中）" in md
