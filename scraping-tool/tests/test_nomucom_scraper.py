"""nomucom_scraper のリストパース（ゴールデン）テスト。

HTML 構造が変わってパースが崩れたことを CI で検知するための固定 fixture。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from nomucom_scraper import parse_list_html


FIXTURE = """
<html><body>
<div class="item_resultsmall">
  <div class="item_title">
    <a class="click_R_link" href="/mansion/id/12345/">テストレジデンス豊洲</a>
  </div>
  <div class="item_resultsmall_lower">
    <table><tr>
      <td class="item_2">
        <p class="item_location">東京都江東区豊洲5丁目</p>
        <p class="item_access">東京メトロ有楽町線「豊洲」駅 徒歩7分</p>
      </td>
      <td class="item_3"><p class="item_price">9,480万円</p></td>
      <td class="item_4">75.2m<sup>2</sup><br>3LDK<br>南東</td>
      <td class="item_5">2015年3月<br>12階 / 20階建<br>総戸数150戸</td>
    </tr></table>
  </div>
</div>
</body></html>
"""


def test_parse_basic_card():
    items = parse_list_html(FIXTURE)
    assert len(items) == 1
    item = items[0]
    assert item.name == "テストレジデンス豊洲"
    assert item.url == "https://www.nomu.com/mansion/id/12345/"
    assert item.price_man == 9480
    assert item.address == "東京都江東区豊洲5丁目"
    assert item.walk_min == 7
    assert item.area_m2 == 75.2
    assert item.layout == "3LDK"
    assert item.built_year == 2015
    assert item.floor_position == 12
    assert item.floor_total == 20
    assert item.total_units == 150


def test_parse_empty_html():
    assert parse_list_html("<html><body></body></html>") == []


def test_card_without_url_skipped():
    html = '<html><body><div class="item_resultsmall"><div class="item_title"></div></div></body></html>'
    assert parse_list_html(html) == []
