"""rehouse_scraper のリストパーステスト。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from rehouse_scraper import parse_list_html


def _card_html(line2: str, name: str = "テストマンション") -> str:
    return f"""
    <div class="property-index-card">
      <a href="/buy/mansion/bkdetail/F12345/">
        <h2 class="property-title">{name}</h2>
      </a>
      <span class="price">9,800</span>
      <div class="content">
        <p class="paragraph-body gray">港区浜松町１丁目 / 山手線 浜松町駅 徒歩5分</p>
        <p class="paragraph-body gray">{line2}</p>
      </div>
    </div>
    """


def test_parse_basic_card():
    html = f"<html><body>{_card_html('3LDK / 87.56㎡ / 2019年02月築 / 36階')}</body></html>"
    items = parse_list_html(html)
    assert len(items) == 1
    item = items[0]
    assert item.name == "テストマンション"
    assert item.price_man == 9800
    assert item.layout == "3LDK"
    assert item.area_m2 == 87.56
    assert item.built_year == 2019
    assert item.walk_min == 5
    assert item.floor_position == 36


def test_parse_floor_total_extracted_when_present():
    """「N階建」表記がある場合 floor_total が抽出される。

    floor_total が常に None だと identity_key の floor 要素が欠け、
    他ソースの同一物件との dedup 判定で誤マージの温床になる。
    """
    html = f"<html><body>{_card_html('3LDK / 87.56㎡ / 2019年02月築 / 5階 / 36階建')}</body></html>"
    items = parse_list_html(html)
    assert len(items) == 1
    assert items[0].floor_position == 5
    assert items[0].floor_total == 36


def test_parse_floor_total_only():
    """所在階なしで「N階建」だけの場合、floor_position は None のまま。"""
    html = f"<html><body>{_card_html('3LDK / 87.56㎡ / 2019年02月築 / 36階建')}</body></html>"
    items = parse_list_html(html)
    assert len(items) == 1
    assert items[0].floor_position is None
    assert items[0].floor_total == 36


def test_parse_empty_html_returns_empty():
    assert parse_list_html("<html><body></body></html>") == []
