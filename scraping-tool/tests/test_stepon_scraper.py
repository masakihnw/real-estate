"""stepon_scraper のリストパース（ゴールデン）テスト。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from stepon_scraper import parse_list_html


FIXTURE = """
<html><body>
<div class="property-card">
  <h3>ステップマンション品川</h3>
  <a href="/mansion/tokyo/B1234567/">詳細を見る</a>
  <p>東京都品川区東品川2丁目</p>
  <p>ＪＲ山手線「品川」駅 徒歩9分</p>
  <p>価格 8,980万円</p>
  <p>3LDK / 72.5m2</p>
  <p>2012年8月築</p>
  <p>10階 / 15階建 総戸数88戸</p>
</div>
</body></html>
"""


def test_parse_card_strategy():
    items = parse_list_html(FIXTURE)
    assert len(items) == 1
    item = items[0]
    assert item.name == "ステップマンション品川"
    assert item.url.endswith("/mansion/tokyo/B1234567/")
    assert item.price_man == 8980
    assert item.area_m2 == 72.5
    assert item.walk_min == 9
    assert item.built_year == 2012
    assert item.floor_position == 10
    assert item.floor_total == 15
    assert item.total_units == 88


def test_parse_empty_html():
    assert parse_list_html("<html><body></body></html>") == []
