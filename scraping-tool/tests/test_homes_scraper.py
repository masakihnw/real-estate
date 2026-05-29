"""
homes_scraper の _extract_card_listings テスト。
コンテナ探索・物件名抽出・_table_value のバグ修正を検証。
"""
import sys
from unittest.mock import MagicMock

pw_mock = MagicMock()
sys.modules.setdefault("playwright", pw_mock)
sys.modules.setdefault("playwright.sync_api", pw_mock)

import pytest
from bs4 import BeautifulSoup

from homes_scraper import _extract_card_listings


BASE_URL = "https://www.homes.co.jp"


def _make_card_html(
    url: str = "/mansion/b-9999/",
    name: str = "テストマンション",
    address: str = "東京都江東区東陽1",
    price: str = "5,980万円",
    area: str = "70.5m²",
    layout: str = "3LDK",
    built: str = "2020年3月",
) -> str:
    return f"""
    <div>
      <h3><a href="{url}">{name}</a></h3>
      <table>
        <tr><th>所在地</th><td>{address}</td></tr>
        <tr><th>価格</th><td>{price}</td></tr>
        <tr><th>専有面積</th><td>{area}</td></tr>
        <tr><th>間取り</th><td>{layout}</td></tr>
        <tr><th>築年月</th><td>{built}</td></tr>
      </table>
    </div>
    """


def _make_dl_card_html(
    url: str = "/mansion/b-8888/",
    name: str = "DLマンション",
    address: str = "東京都墨田区両国1",
    area: str = "65.0m²",
    layout: str = "2LDK",
) -> str:
    """dt/dd ベースの物件カード（テーブルなし）。"""
    return f"""
    <div>
      <h2><a href="{url}">{name}</a></h2>
      <dl>
        <dt>所在地</dt><dd>{address}</dd>
        <dt>専有面積</dt><dd>{area}</dd>
        <dt>間取り</dt><dd>{layout}</dd>
        <dt>価格</dt><dd>6,280万円</dd>
      </dl>
    </div>
    """


class TestExtractCardListingsNormal:
    """正常系: 単一物件カードから正しく抽出できる。"""

    def test_single_card_basic_fields(self):
        html = f"<html><body>{_make_card_html()}</body></html>"
        soup = BeautifulSoup(html, "lxml")
        items = _extract_card_listings(soup, BASE_URL)
        assert len(items) == 1
        item = items[0]
        assert item.name == "テストマンション"
        assert item.address == "東京都江東区東陽1"
        assert item.layout == "3LDK"
        assert item.area_m2 == 70.5
        assert item.built_year == 2020

    def test_multiple_cards_each_extracted(self):
        card1 = _make_card_html(url="/mansion/b-1001/", name="クレヴィア住吉")
        card2 = _make_card_html(url="/mansion/b-1002/", name="プラウド東陽町")
        html = f"<html><body>{card1}{card2}</body></html>"
        soup = BeautifulSoup(html, "lxml")
        items = _extract_card_listings(soup, BASE_URL)
        assert len(items) == 2
        names = {i.name for i in items}
        assert names == {"クレヴィア住吉", "プラウド東陽町"}

    def test_dl_dd_layout(self):
        """dt/dd ベースのカードからもデータ抽出できる。"""
        html = f"<html><body>{_make_dl_card_html()}</body></html>"
        soup = BeautifulSoup(html, "lxml")
        items = _extract_card_listings(soup, BASE_URL)
        assert len(items) == 1
        item = items[0]
        assert item.name == "DLマンション"
        assert item.address == "東京都墨田区両国1"
        assert item.layout == "2LDK"


class TestExtractCardListingsPageTitleReject:
    """ページタイトルが物件名にならないことを検証。"""

    def test_page_title_in_h2_rejected(self):
        """コンテナ内にページタイトルの h2 があっても物件名にならない。"""
        html = """
        <html><body>
          <div>
            <h2>東京都の新築マンション・分譲マンション物件一覧</h2>
            <div>
              <h3><a href="/mansion/b-5555/">レジデンス東陽町</a></h3>
              <table>
                <tr><th>所在地</th><td>東京都江東区東陽1</td></tr>
                <tr><th>価格</th><td>5,980万円</td></tr>
                <tr><th>専有面積</th><td>70.5m²</td></tr>
              </table>
            </div>
          </div>
        </body></html>
        """
        soup = BeautifulSoup(html, "lxml")
        items = _extract_card_listings(soup, BASE_URL)
        for item in items:
            assert "物件一覧" not in item.name

    def test_button_text_rejected(self):
        """リンクテキストが「見学予約」の場合、物件名にならない。"""
        html = """
        <html><body>
          <div>
            <a href="/mansion/b-7777/">見学予約</a>
            <table>
              <tr><th>所在地</th><td>東京都港区浜松町2</td></tr>
              <tr><th>価格</th><td>8,000万円</td></tr>
              <tr><th>専有面積</th><td>60.0m²</td></tr>
            </table>
          </div>
        </body></html>
        """
        soup = BeautifulSoup(html, "lxml")
        items = _extract_card_listings(soup, BASE_URL)
        for item in items:
            assert item.name != "見学予約"


class TestContainerScopeLimit:
    """コンテナ探索が body レベルに到達しないことを検証。"""

    def test_too_wide_container_rejected(self):
        """4つ以上の異なる物件リンクを含むコンテナは拒否される。"""
        cards = ""
        for i in range(5):
            cards += _make_card_html(
                url=f"/mansion/b-{2000 + i}/",
                name=f"マンション{i}",
            )
        html = f"""
        <html><body>
          <div>
            <table><tr><th>所在地</th><td>東京都</td></tr></table>
            {cards}
          </div>
        </body></html>
        """
        soup = BeautifulSoup(html, "lxml")
        items = _extract_card_listings(soup, BASE_URL)
        for item in items:
            assert item.name != ""
            assert "物件一覧" not in item.name

    def test_no_address_and_price_container_skipped(self):
        """「所在地」がなく「万円」もないコンテナは物件ブロックとみなされない。"""
        html = """
        <html><body>
          <div>
            <a href="/mansion/b-6666/">テスト</a>
            <table>
              <tr><th>間取り</th><td>3LDK</td></tr>
            </table>
          </div>
        </body></html>
        """
        soup = BeautifulSoup(html, "lxml")
        items = _extract_card_listings(soup, BASE_URL)
        assert len(items) == 0


class TestNameOrUrlRequired:
    """名前なし物件はスキップされることを検証。"""

    def test_empty_name_skipped(self):
        """物件名が空（ページタイトルのみ等）の場合は登録されない。"""
        html = """
        <html><body>
          <div>
            <h2>東京都の新築マンション・分譲マンション物件一覧</h2>
            <a href="/mansion/b-3333/"></a>
            <table>
              <tr><th>所在地</th><td>東京都新宿区横寺町</td></tr>
              <tr><th>価格</th><td>4,000万円</td></tr>
              <tr><th>専有面積</th><td>34.49m²</td></tr>
            </table>
          </div>
        </body></html>
        """
        soup = BeautifulSoup(html, "lxml")
        items = _extract_card_listings(soup, BASE_URL)
        assert all(item.name != "" for item in items)
