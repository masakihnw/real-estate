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

from homes_scraper import (
    HomesListing,
    _extract_card_listings,
    _extract_html_layout_walk,
    _split_feature_comment,
    apply_conditions,
    parse_list_html,
)


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


class TestSplitFeatureComment:
    """textFeatureComment（■建物名■〇〇駅徒歩X分）の分離を検証。"""

    def test_decorated_name_and_station(self):
        name, station = _split_feature_comment("■レグノ・セレーノ■大久保駅徒歩3分")
        assert name == "レグノ・セレーノ"
        assert station == "大久保駅徒歩3分"

    def test_name_with_trailing_area_text_before_station(self):
        # 建物名の後に「港区高輪・」のようなエリア表記が入っても駅徒歩だけ取る
        name, station = _split_feature_comment("■朝日シティパリオ高輪台■港区高輪・高輪駅徒歩6分")
        assert name == "朝日シティパリオ高輪台"
        assert station == "高輪駅徒歩6分"

    def test_catchphrase_is_not_a_name(self):
        # ◆…×…◆ はキャッチコピー → 建物名として弾かれる
        name, station = _split_feature_comment(
            "◆戸建て感覚のメゾネットタイプ×オール電化◆赤坂駅徒歩8分"
        )
        assert name == ""
        assert station == "赤坂駅徒歩8分"

    def test_no_decoration_station_only(self):
        name, station = _split_feature_comment("潮見駅徒歩3分")
        assert name == ""
        assert station == "潮見駅徒歩3分"

    def test_name_without_station_pattern_returns_empty_station(self):
        # 駅徒歩表記が無ければ station は "" を返し、呼び出し側のフォールバックに委ねる
        name, station = _split_feature_comment("■ビュロー平河町■都心の邸宅")
        assert name == "ビュロー平河町"
        assert station == ""

    def test_empty(self):
        assert _split_feature_comment("") == ("", "")
        assert _split_feature_comment(None) == ("", "")


class TestListKksNameRecovery:
    """mod-listKks カードで JSON-LD に名前が無くても textFeatureComment から復旧する。"""

    def _kks_html(self, url: str, feature_comment: str) -> str:
        return f"""
        <html><body>
          <div class="mod-listKks mod-listKks-sale cMansion">
            <a class="prg-detailLink" href="{url}">詳細を見る</a>
            <table class="verticalTable">
              <tr><th>間取り</th><td>3LDK</td></tr>
            </table>
            <p class="textFeatureComment">{feature_comment}</p>
          </div>
        </body></html>
        """

    def test_html_map_recovers_name_and_clean_station(self):
        soup = BeautifulSoup(
            self._kks_html("/mansion/b-1001/", "■レグノ・セレーノ■大久保駅徒歩3分"), "lxml"
        )
        by_url = _extract_html_layout_walk(soup, BASE_URL)
        entry = by_url["https://www.homes.co.jp/mansion/b-1001/"]
        assert entry["name"] == "レグノ・セレーノ"
        assert entry["station_line"] == "大久保駅徒歩3分"

    def test_mergebuilding_keeps_line_station_when_comment_has_no_walk(self):
        # mod-mergeBuilding: textFeatureComment に駅徒歩が無い場合、
        # 建物の交通セル（路線名付き）の station_line を保持する（説明文で潰さない）。
        html = """
        <html><body>
          <div class="mod-mergeBuilding--sale cMansion">
            <div class="bukkenSpec">
              <table class="verticalTable">
                <tr><th>交通</th><td>東京メトロ東西線 東陽町駅 徒歩5分</td></tr>
              </table>
            </div>
            <table class="unitSummary"><tbody>
              <tr data-href="/mansion/b-2002/">
                <td class="info"><span>3階</span>
                  <table class="verticalTable"><tr><th>間取り</th><td>2LDK</td></tr></table>
                </td>
              </tr>
              <tr class="memberDataRow">
                <td><p class="textFeatureComment">■パークタワー東陽町■都心近接の邸宅</p></td>
              </tr>
            </tbody></table>
          </div>
        </body></html>
        """
        soup = BeautifulSoup(html, "lxml")
        by_url = _extract_html_layout_walk(soup, BASE_URL)
        entry = by_url["https://www.homes.co.jp/mansion/b-2002/"]
        assert entry["name"] == "パークタワー東陽町"
        # 路線名付きの交通セルが保持される（textFeatureComment 全文で上書きされない）
        assert "東京メトロ東西線" in entry["station_line"]

    def test_parse_list_html_falls_back_to_html_name(self):
        # JSON-LD は name 空、HTML（textFeatureComment）に建物名がある状況
        jsonld = """
        <script type="application/ld+json">
        {"@type":"ItemList","itemListElement":[
          {"item":{"@type":"Product","name":"","url":"https://www.homes.co.jp/mansion/b-1001/",
            "offers":{"price":101800000,
              "itemOffered":{"floorSize":{"value":78.9},"yearBuilt":1998,
                "address":{"name":"東京都新宿区北新宿3丁目"}}}}}
        ]}
        </script>
        """
        html = self._kks_html("/mansion/b-1001/", "■レグノ・セレーノ■大久保駅徒歩3分").replace(
            "<body>", f"<body>{jsonld}"
        )
        items = parse_list_html(html, BASE_URL)
        assert len(items) == 1
        assert items[0].name == "レグノ・セレーノ"
        assert items[0].station_line == "大久保駅徒歩3分"


def _make_homes_listing(**overrides) -> HomesListing:
    defaults = dict(
        source="homes",
        url="https://www.homes.co.jp/mansion/b-99999/",
        name="テストマンション",
        price_man=10000,
        address="東京都江東区東陽1",
        station_line="東京メトロ東西線「東陽町」徒歩5分",
        walk_min=5,
        area_m2=65.0,
        layout="3LDK",
        built_str="2015年3月",
        built_year=2015,
        total_units=100,
    )
    defaults.update(overrides)
    return HomesListing(**defaults)


class TestApplyConditionsNullPrice:
    """price_man=None（価格未定）の物件が除外されることを検証。"""

    def test_null_price_excluded(self, monkeypatch):
        monkeypatch.setattr("homes_scraper.is_tokyo_23_by_address", lambda *args: True)
        monkeypatch.setattr("homes_scraper.line_ok", lambda *args, **kwargs: True)
        monkeypatch.setattr("homes_scraper.station_passengers_ok", lambda *args: True)
        monkeypatch.setattr("homes_scraper.load_station_passengers", lambda: {})
        monkeypatch.setattr("homes_scraper.lower_tier_station_ok", lambda *args: True)
        monkeypatch.setattr("homes_scraper.get_effective_area_min_m2", lambda *args: 50.0)
        monkeypatch.setattr("homes_scraper.layout_ok", lambda *args: True)
        row = _make_homes_listing(price_man=None)
        assert apply_conditions([row]) == []

    def test_valid_price_passes(self, monkeypatch):
        monkeypatch.setattr("homes_scraper.is_tokyo_23_by_address", lambda *args: True)
        monkeypatch.setattr("homes_scraper.line_ok", lambda *args, **kwargs: True)
        monkeypatch.setattr("homes_scraper.station_passengers_ok", lambda *args: True)
        monkeypatch.setattr("homes_scraper.load_station_passengers", lambda: {})
        monkeypatch.setattr("homes_scraper.lower_tier_station_ok", lambda *args: True)
        monkeypatch.setattr("homes_scraper.get_effective_area_min_m2", lambda *args: 50.0)
        monkeypatch.setattr("homes_scraper.layout_ok", lambda *args: True)
        row = _make_homes_listing(price_man=10000)
        result = apply_conditions([row])
        assert len(result) == 1


# ──────────────────────────── scrape_homes ループの終端理由テスト ────────────────────────────

from types import SimpleNamespace

import homes_scraper
import scraper_metrics


@pytest.fixture(autouse=True)
def _reset_metrics():
    scraper_metrics.reset()
    yield
    scraper_metrics.reset()


def _run_scrape_homes(monkeypatch, pages: dict[int, int], max_pages: int = 0) -> list:
    """ページ番号→行数 の辞書で Playwright/fetch/parse を偽装して scrape_homes を実行する。"""
    monkeypatch.setattr(homes_scraper, "HAS_PLAYWRIGHT", True)
    monkeypatch.setattr(
        homes_scraper, "_launch_browser",
        lambda: (MagicMock(), MagicMock(), MagicMock()),
    )
    monkeypatch.setattr(homes_scraper, "_build_list_url", lambda page, apply_filter: f"page={page}")
    monkeypatch.setattr(homes_scraper, "fetch_list_page", lambda context, url: url)
    monkeypatch.setattr(homes_scraper, "HOMES_REQUEST_DELAY_SEC", 0)

    def fake_parse(html):
        page = int(html.split("=", 1)[1])
        return [SimpleNamespace(url=f"u{page}-{i}") for i in range(pages.get(page, 0))]

    monkeypatch.setattr(homes_scraper, "parse_list_html", fake_parse)
    monkeypatch.setattr(homes_scraper, "dump_debug_html", lambda *a: None)
    monkeypatch.setattr(homes_scraper, "HOMES_EMPTY_PARSE_BACKOFF_SEC", 0)
    return list(homes_scraper.scrape_homes(max_pages=max_pages, apply_filter=False))


class TestScrapeHomesFinishReasons:
    def test_normal_termination(self, monkeypatch):
        results = _run_scrape_homes(monkeypatch, {1: 3, 2: 2, 3: 0})
        assert len(results) == 5
        entry = scraper_metrics.get_all()["homes"]
        assert entry["parsed"] == 5
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []

    def test_timeout_records_reason(self, monkeypatch):
        """30分タイムリミット打ち切り（82ページで停止していた実ケース）を異常終端として記録。"""
        monkeypatch.setattr(homes_scraper, "HOMES_SCRAPE_TIMEOUT_SEC", -1)  # 即タイムアウト
        results = _run_scrape_homes(monkeypatch, {1: 3})
        assert results == []
        entry = scraper_metrics.get_all()["homes"]
        assert entry["finish_reasons"] == {"timeout": 1}
        assert any("homes" in a and "timeout" in a for a in scraper_metrics.health_alerts())

    def test_empty_html_records_waf_abort(self, monkeypatch):
        monkeypatch.setattr(homes_scraper, "HAS_PLAYWRIGHT", True)
        monkeypatch.setattr(
            homes_scraper, "_launch_browser",
            lambda: (MagicMock(), MagicMock(), MagicMock()),
        )
        monkeypatch.setattr(homes_scraper, "fetch_list_page", lambda context, url: "")
        results = list(homes_scraper.scrape_homes(max_pages=0, apply_filter=False))
        assert results == []
        entry = scraper_metrics.get_all()["homes"]
        assert entry["finish_reasons"] == {"waf_abort": 1}

    def test_empty_first_page_records_abort(self, monkeypatch):
        """全ページ空のときは連続2回（tolerance）試した上で全損として記録。"""
        results = _run_scrape_homes(monkeypatch, {1: 0})
        assert results == []
        entry = scraper_metrics.get_all()["homes"]
        assert entry["finish_reasons"] == {"empty_parse_abort": 1}
        assert entry["empty_pages"] == 2  # HOMES_EMPTY_PARSE_TOLERANCE 回分
        assert any("媒体全損" in a for a in scraper_metrics.health_alerts())

    def test_single_empty_page_does_not_abort(self, monkeypatch):
        """空ページ1回では打ち切らず、後続ページの物件を取りこぼさない（HOME'S実事故対策）。"""
        results = _run_scrape_homes(monkeypatch, {1: 3, 2: 0, 3: 2})
        assert len(results) == 5, "空ページ1回で残ページが打ち切られている"
        entry = scraper_metrics.get_all()["homes"]
        assert entry["parsed"] == 5
        assert entry["empty_pages"] == 1  # 途中ギャップのみ（終端の連続空は正常終端）
        assert entry["finish_reasons"] == {"completed": 1}

    def test_safety_limit_full_run(self, monkeypatch):
        monkeypatch.setattr(homes_scraper, "HOMES_MAX_PAGES_SAFETY", 2)
        _run_scrape_homes(monkeypatch, {1: 2, 2: 2, 3: 2}, max_pages=0)
        entry = scraper_metrics.get_all()["homes"]
        assert entry["finish_reasons"] == {"safety_limit": 1}

    def test_safety_limit_covers_large_inventory(self):
        """安全上限は実在庫（2026-06: 100ページ超）を巡回しきれる幅を確保する。

        100 では safety_limit で打ち切られ取りこぼしていたため引き上げた。回帰防止。
        """
        assert homes_scraper.HOMES_MAX_PAGES_SAFETY >= 150

    def test_user_limit_records_completed(self, monkeypatch):
        _run_scrape_homes(monkeypatch, {1: 2, 2: 2, 3: 2}, max_pages=2)
        entry = scraper_metrics.get_all()["homes"]
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []

    def test_generator_early_close_still_records_finish(self, monkeypatch):
        """呼び出し元が break してもジェネレータの終端理由が記録される（漏れ防止）。"""
        monkeypatch.setattr(homes_scraper, "HAS_PLAYWRIGHT", True)
        monkeypatch.setattr(
            homes_scraper, "_launch_browser",
            lambda: (MagicMock(), MagicMock(), MagicMock()),
        )
        monkeypatch.setattr(homes_scraper, "_build_list_url", lambda page, apply_filter: f"page={page}")
        monkeypatch.setattr(homes_scraper, "fetch_list_page", lambda context, url: url)
        monkeypatch.setattr(homes_scraper, "HOMES_REQUEST_DELAY_SEC", 0)
        monkeypatch.setattr(
            homes_scraper, "parse_list_html",
            lambda html: [SimpleNamespace(url=f"u{i}") for i in range(5)],
        )

        gen = homes_scraper.scrape_homes(max_pages=0, apply_filter=False)
        next(gen)
        gen.close()  # for ループ内 break と同じ経路

        entry = scraper_metrics.get_all()["homes"]
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []


class TestBuildListUrl:
    """サーバーサイドフィルタURL生成のテスト（30分タイムアウト対策）。"""

    def test_no_filter_page_1_has_sort_only(self):
        """フィルタ無しでも並び順（新着順）は常に付く。"""
        from urllib.parse import urlencode
        url = homes_scraper._build_list_url(1, apply_filter=False)
        expected = homes_scraper.LIST_URL_BASE + "?" + urlencode(
            {"cond[sortby]": homes_scraper.HOMES_SORT_NEWEST}
        )
        assert url == expected
        assert "page=" not in url

    def test_no_filter_page_2(self):
        url = homes_scraper._build_list_url(2, apply_filter=False)
        assert "cond%5Bsortby%5D=newdate" in url
        assert "page=2" in url
        assert "cond%5Bmoneyroom%5D=" not in url

    def test_sort_is_always_newest(self):
        """全ページ・全モードで新着順固定（安全上限の取りこぼしを古い物件側に寄せる）。"""
        assert homes_scraper.HOMES_SORT_NEWEST == "newdate"
        for apply_filter in (True, False):
            for page in (1, 5):
                url = homes_scraper._build_list_url(page, apply_filter=apply_filter)
                assert "cond%5Bsortby%5D=newdate" in url

    def test_filter_adds_price_and_area(self):
        url = homes_scraper._build_list_url(1, apply_filter=True)
        assert "cond%5Bmoneyroom%5D=" in url
        assert "cond%5Bhousearea%5D=" in url
        assert "cond%5Bsortby%5D=newdate" in url

    def test_filter_with_page(self):
        url = homes_scraper._build_list_url(3, apply_filter=True)
        assert "page=3" in url
        assert "cond%5Bmoneyroom%5D=" in url

    def test_price_snaps_down_to_option(self):
        """下限は取りこぼし防止のため value 以下の最大選択肢に丸める。"""
        # PRICE_MIN_MAN=7500 → 選択肢 7000（7500以下の最大）
        assert homes_scraper._snap_down(7500, homes_scraper._HOMES_PRICE_OPTIONS) == 7000
        # ちょうど一致する値はそのまま
        assert homes_scraper._snap_down(7000, homes_scraper._HOMES_PRICE_OPTIONS) == 7000
        # 全選択肢より小さい→0（フィルタなし）
        assert homes_scraper._snap_down(100, homes_scraper._HOMES_PRICE_OPTIONS) == 0

    def test_area_snaps_down_to_option(self):
        assert homes_scraper._snap_down(55, homes_scraper._HOMES_AREA_OPTIONS) == 55
        assert homes_scraper._snap_down(58, homes_scraper._HOMES_AREA_OPTIONS) == 55

    def test_snapped_filter_is_looser_than_local(self):
        """サーバーフィルタは必ずローカル条件以下（フェイルクローズ）。"""
        from config import PRICE_MIN_MAN
        from scraper_common import AREA_MIN_M2_FETCH
        price_floor = homes_scraper._snap_down(PRICE_MIN_MAN, homes_scraper._HOMES_PRICE_OPTIONS)
        area_floor = homes_scraper._snap_down(int(AREA_MIN_M2_FETCH), homes_scraper._HOMES_AREA_OPTIONS)
        assert price_floor <= PRICE_MIN_MAN
        assert area_floor <= AREA_MIN_M2_FETCH
