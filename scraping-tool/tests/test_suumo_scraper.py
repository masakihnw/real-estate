"""suumo_scraper の主要ヘルパーのテスト。"""
import importlib.util
from pathlib import Path

from suumo_scraper import (
    SuumoListing,
    _fetch_and_parse_detail,
    _is_tower_name,
    _passes_basic_filters,
    _snap_kt_server,
    apply_conditions,
    parse_suumo_detail_html,
)


def _load_script_module(name: str, relative_path: str):
    script_path = Path(__file__).resolve().parents[1] / relative_path
    spec = importlib.util.spec_from_file_location(name, script_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_snap_kt_server_11500_to_12000():
    """SUUMO は kt=11500 を拒否するため 12000 に切り上げる。"""
    assert _snap_kt_server(9000, 11500) == 12000


def test_snap_kt_server_exact_tier():
    assert _snap_kt_server(9000, 10000) == 10000
    assert _snap_kt_server(9000, 12000) == 12000


def test_snap_kt_server_kb_narrow_gap():
    """kb に対し kt は大きい必要がある。"""
    assert _snap_kt_server(8990, 10000) == 10000


def test_parse_suumo_detail_html_total_units_and_floor():
    """総戸数・所在階・階建が1行ずつあるレイアウト。"""
    html = """
    <table>
    <tr>
        <th><div class="fl">総戸数</div></th>
        <td class="bdCell">38戸</td>
    </tr>
    <tr>
        <th><div class="fl">所在階</div></th>
        <td class="bdCell">12階</td>
        <th><div class="fl">向き</div></th>
        <td class="bdCell">北西</td>
    </tr>
    <tr>
        <th><div class="fl">構造・階建て</div></th>
        <td class="bdCell">RC13階地下1階建</td>
    </tr>
    </table>
    """
    r = parse_suumo_detail_html(html)
    assert r["total_units"] == 38
    assert r["floor_position"] == 12
    assert r["floor_total"] == 13


def test_parse_suumo_detail_html_combined_floor_cell():
    """所在階/構造・階建が1セルで「12階/RC13階地下1階建」の形式。"""
    html = """
    <tr>
        <th><div class="fl">所在階/構造・階建</div></th>
        <td class="bdCell">12階/RC13階地下1階建</td>
    </tr>
    """
    r = parse_suumo_detail_html(html)
    assert r["floor_position"] == 12
    assert r["floor_total"] == 13
    assert r["floor_structure"] == "RC13階地下1階建"
    assert r["total_units"] is None


def test_parse_suumo_detail_html_empty():
    """該当する th が無い場合は None。"""
    r = parse_suumo_detail_html("<html><body><p>no table</p></body></html>")
    assert r["total_units"] is None
    assert r["floor_position"] is None
    assert r["floor_total"] is None
    assert r["floor_structure"] is None
    assert r["ownership"] is None


def test_parse_suumo_detail_html_delisted_page():
    html = """
    <section>
      <h1>アスコットパーク日本橋浜町公園</h1>
      <p>※このページは過去の掲載情報を元に作成しています。</p>
    </section>
    """
    assert parse_suumo_detail_html(html) == {"delisted": True}


def _make_detail_listing(**overrides) -> SuumoListing:
    """_fetch_and_parse_detail テスト用 SuumoListing ファクトリ。"""
    defaults = dict(
        source="suumo",
        url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_99999999/",
        name="テストマンション",
        price_man=10000,
        address="東京都江東区毛利1",
        station_line="東京メトロ半蔵門線「住吉」徒歩6分",
        walk_min=6,
        area_m2=65.0,
        layout="3LDK",
        built_str="2014年2月",
        built_year=2014,
    )
    defaults.update(overrides)
    return SuumoListing(**defaults)


def test_fetch_and_parse_detail_returns_fetch_failed_on_error(monkeypatch):
    """詳細ページ取得失敗時は fetch_failed=True を返す。"""
    def _raise(*_a, **_kw):
        raise ConnectionError("mock network error")

    monkeypatch.setattr("suumo_scraper._fetch_detail_page", _raise)

    row = _make_detail_listing()
    detail_cache: dict[str, dict] = {}
    result = _fetch_and_parse_detail(row, session=object(), detail_cache=detail_cache)
    assert result.get("fetch_failed") is True
    assert detail_cache[row.url].get("fetch_failed") is True


def test_fetch_and_parse_detail_cache_hit_with_fetch_failed(monkeypatch):
    """fetch_failed がキャッシュされている場合、再取得せずそのまま返す。"""
    url = "https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_88888888/"
    row = _make_detail_listing(url=url)
    detail_cache = {url: {"fetch_failed": True}}
    result = _fetch_and_parse_detail(row, session=object(), detail_cache=detail_cache)
    assert result.get("fetch_failed") is True


def test_parse_suumo_detail_html_only_units():
    """総戸数のみ。"""
    html = """
    <tr>
        <th><div class="fl">総戸数</div></th>
        <td>100戸</td>
    </tr>
    """
    r = parse_suumo_detail_html(html)
    assert r["total_units"] == 100
    assert r["floor_position"] is None
    assert r["floor_total"] is None
    assert r["floor_structure"] is None


def test_is_tower_name_detects_tower_keywords():
    assert _is_tower_name("プラウドタワー亀戸クロス")
    assert _is_tower_name("THE TOWER TOYOSU")
    assert not _is_tower_name("ライオンズマンション大井町")


def test_apply_conditions_fetches_detail_for_old_unknown_tower(monkeypatch):
    monkeypatch.setattr("suumo_scraper._is_tokyo_23", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.line_ok", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.station_passengers_ok", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.load_station_passengers", lambda: {})
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {})
    monkeypatch.setattr("suumo_scraper.create_session", lambda: object())
    monkeypatch.setattr("suumo_scraper._fetch_detail_page", lambda *_args, **_kwargs: "<html></html>")
    monkeypatch.setattr("suumo_scraper.parse_suumo_detail_html", lambda *_args, **_kwargs: {
        "floor_position": 24,
        "floor_total": 31,
        "total_units": 290,
    })

    row = SuumoListing(
        source="suumo",
        url="https://example.com/city-front-tower",
        name="シティフロント",
        price_man=11000,
        address="東京都中央区佃1-1-1",
        station_line="東京メトロ有楽町線「月島」駅 徒歩6分",
        walk_min=6,
        area_m2=75.0,
        layout="2LDK",
        built_str="1991年8月",
        built_year=1991,
    )

    result = apply_conditions([row])
    assert len(result) == 1
    assert row.floor_position == 24
    assert row.floor_total == 31
    assert row.total_units == 290


def test_apply_conditions_skips_delisted_cache(monkeypatch):
    monkeypatch.setattr("suumo_scraper._is_tokyo_23", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.line_ok", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.station_passengers_ok", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.load_station_passengers", lambda: {})
    url = "https://suumo.jp/ms/chuko/tokyo/sc_chuo/nc_20326695/"
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {url: {"delisted": True}})

    row = SuumoListing(
        source="suumo",
        url=url,
        name="アスコットパーク日本橋浜町公園",
        price_man=10840,
        address="東京都中央区日本橋浜町2",
        station_line="都営新宿線「浜町」歩3分",
        walk_min=3,
        area_m2=61.79,
        layout="2LDK",
        built_str="2006年1月",
        built_year=2006,
    )

    assert apply_conditions([row]) == []


def test_build_units_cache_entry_preserves_delisted():
    module = _load_script_module("build_units_cache", "scripts/build_units_cache.py")
    assert module._detail_to_cache_entry({"delisted": True}) == {"delisted": True}


def test_merge_detail_cache_removes_delisted_suumo_listing():
    module = _load_script_module("merge_detail_cache", "scripts/merge_detail_cache.py")
    listings = [
        {
            "source": "suumo",
            "url": "https://suumo.jp/ms/chuko/tokyo/sc_chuo/nc_20326695/",
            "name": "アスコットパーク日本橋浜町公園",
            "total_units": None,
        },
        {
            "source": "livable",
            "url": "https://example.com/keep",
            "name": "他社物件",
        },
    ]
    cache = {
        "https://suumo.jp/ms/chuko/tokyo/sc_chuo/nc_20326695/": {"delisted": True},
    }

    merged_listings, merged_count, removed_count = module.merge_detail_cache(listings, cache)

    assert merged_count == 0
    assert removed_count == 1
    assert [r["name"] for r in merged_listings] == ["他社物件"]


# ---------- 掲載終了チェック統合テスト ----------


def _make_listing(**overrides) -> SuumoListing:
    """テスト用 SuumoListing ファクトリ。"""
    defaults = dict(
        source="suumo",
        url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_99999999/",
        name="テストマンション",
        price_man=10000,
        address="東京都江東区毛利1",
        station_line="東京メトロ半蔵門線「住吉」徒歩6分",
        walk_min=6,
        area_m2=65.0,
        layout="3LDK",
        built_str="2014年2月",
        built_year=2014,
        total_units=100,
    )
    defaults.update(overrides)
    return SuumoListing(**defaults)


def _common_monkeypatches(monkeypatch):
    """apply_conditions テスト共通のモック設定。"""
    monkeypatch.setattr("suumo_scraper._is_tokyo_23", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.line_ok", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.station_passengers_ok", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.load_station_passengers", lambda: {})
    monkeypatch.setattr("suumo_scraper.lower_tier_station_ok", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.get_effective_area_min_m2", lambda *args: 50.0)
    monkeypatch.setattr("suumo_scraper.layout_ok", lambda *args: True)


def test_apply_conditions_excludes_delisted_detail_page(monkeypatch):
    """詳細ページで掲載終了が検出された場合、キャッシュに無くても除外される。"""
    _common_monkeypatches(monkeypatch)
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {})
    monkeypatch.setattr("suumo_scraper.create_session", lambda: object())
    delisted_html = '<p>※このページは過去の掲載情報を元に作成しています。</p>'
    monkeypatch.setattr("suumo_scraper._fetch_detail_page", lambda *_a, **_kw: delisted_html)
    monkeypatch.setattr("suumo_scraper.parse_suumo_detail_html",
                        lambda html: {"delisted": True} if "過去の掲載情報" in html else {})

    row = _make_listing()
    result = apply_conditions([row])
    assert result == [], "掲載終了の物件は除外されるべき"


def test_apply_conditions_keeps_active_detail_page(monkeypatch):
    """詳細ページが有効な場合、リストに含まれる。"""
    _common_monkeypatches(monkeypatch)
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {})
    monkeypatch.setattr("suumo_scraper.create_session", lambda: object())
    monkeypatch.setattr("suumo_scraper._fetch_detail_page", lambda *_a, **_kw: "<html></html>")
    monkeypatch.setattr("suumo_scraper.parse_suumo_detail_html",
                        lambda *_a: {"total_units": 100, "floor_position": 5, "floor_total": 11})

    row = _make_listing()
    result = apply_conditions([row])
    assert len(result) == 1
    assert result[0].name == "テストマンション"


def test_apply_conditions_fail_close_on_fetch_error(monkeypatch):
    """詳細ページ取得失敗時はフェイルクローズ（除外する）。"""
    _common_monkeypatches(monkeypatch)
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {})
    monkeypatch.setattr("suumo_scraper.create_session", lambda: object())

    def _raise(*_a, **_kw):
        raise ConnectionError("mock network error")

    monkeypatch.setattr("suumo_scraper._fetch_detail_page", _raise)

    row = _make_listing()
    result = apply_conditions([row])
    assert len(result) == 0, "取得失敗時は除外すべき"


def test_apply_conditions_excludes_old_non_tower_with_known_floor(monkeypatch):
    """築古・floor_total判明・非タワーは除外される。"""
    _common_monkeypatches(monkeypatch)
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {})
    row = _make_listing(built_year=1990, floor_total=10)
    result = apply_conditions([row])
    assert result == [], "築古・非タワーは除外されるべき"


def test_apply_conditions_excludes_delisted_even_when_units_cache_exists(monkeypatch):
    """units_cache に有効エントリがあっても、詳細ページが掲載終了なら除外される。"""
    _common_monkeypatches(monkeypatch)
    url = "https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_20519655/"
    monkeypatch.setattr("suumo_scraper._load_building_units_cache",
                        lambda: {url: {"total_units": 74, "floor_total": 11}})
    monkeypatch.setattr("suumo_scraper.create_session", lambda: object())
    delisted_html = '<p>※このページは過去の掲載情報を元に作成しています。</p>'
    monkeypatch.setattr("suumo_scraper._fetch_detail_page", lambda *_a, **_kw: delisted_html)
    monkeypatch.setattr("suumo_scraper.parse_suumo_detail_html",
                        lambda html: {"delisted": True} if "過去の掲載情報" in html else {})

    row = _make_listing(url=url, total_units=74, floor_total=11)
    result = apply_conditions([row])
    assert result == [], "キャッシュが古くても詳細ページで掲載終了なら除外すべき"


def test_apply_conditions_does_not_double_fetch(monkeypatch):
    """タワー判定でdetail取得済みの物件は掲載終了チェックで再取得しない。"""
    _common_monkeypatches(monkeypatch)
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {})
    monkeypatch.setattr("suumo_scraper.create_session", lambda: object())
    fetch_count = {"n": 0}

    def _count_fetch(*_a, **_kw):
        fetch_count["n"] += 1
        return "<html></html>"

    monkeypatch.setattr("suumo_scraper._fetch_detail_page", _count_fetch)
    monkeypatch.setattr("suumo_scraper.parse_suumo_detail_html",
                        lambda *_a: {"floor_total": 25, "total_units": 300})

    row = _make_listing(built_year=1991, floor_total=None)
    result = apply_conditions([row])
    assert len(result) == 1
    assert fetch_count["n"] == 1, "detail取得は1回のみであるべき"


def test_passes_basic_filters_rejects_null_price(monkeypatch):
    """price_man=None の物件（価格未定）は基本フィルタで除外される。"""
    monkeypatch.setattr("suumo_scraper._is_tokyo_23", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.line_ok", lambda *args, **kwargs: True)
    monkeypatch.setattr("suumo_scraper.station_passengers_ok", lambda *args, **kwargs: True)
    row = _make_listing(price_man=None)
    assert _passes_basic_filters(row, {}) is False


def test_apply_conditions_excludes_null_price(monkeypatch):
    """price_man=None の物件は apply_conditions で除外される。"""
    _common_monkeypatches(monkeypatch)
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {})
    row = _make_listing(price_man=None)
    assert apply_conditions([row]) == []


def test_apply_conditions_keeps_valid_price(monkeypatch):
    """price_man が有効範囲内の物件は通過する。"""
    _common_monkeypatches(monkeypatch)
    monkeypatch.setattr("suumo_scraper._load_building_units_cache", lambda: {})
    monkeypatch.setattr("suumo_scraper.create_session", lambda: object())
    monkeypatch.setattr("suumo_scraper._fetch_detail_page", lambda *_a, **_kw: "<html></html>")
    monkeypatch.setattr("suumo_scraper.parse_suumo_detail_html",
                        lambda *_a: {"total_units": 100, "floor_position": 5, "floor_total": 11})
    row = _make_listing(price_man=10000)
    result = apply_conditions([row])
    assert len(result) == 1


# ---------- パース0件トレランス（_scrape_ward） ----------


def _setup_scrape_ward(monkeypatch, pages: list[list]) -> dict:
    """_scrape_ward 用モック。pages[i] = ページ i+1 のパース結果（範囲外は空）。"""
    from suumo_scraper import _scrape_ward  # noqa: F401  (存在確認)

    calls = {"fetch": 0}
    monkeypatch.setattr("suumo_scraper.create_session", lambda: object())
    monkeypatch.setattr("suumo_scraper.time.sleep", lambda *_a, **_kw: None)

    def _fetch(session, p, ward_roman=None, filtered_base_url=None):
        calls["fetch"] += 1
        return f"<html>page{p}</html>"

    def _parse(html):
        page_no = int(html.split("page")[1].split("<")[0])
        return pages[page_no - 1] if page_no <= len(pages) else []

    monkeypatch.setattr("suumo_scraper.fetch_list_page", _fetch)
    monkeypatch.setattr("suumo_scraper.parse_list_html", _parse)
    return calls


def test_scrape_ward_continues_after_single_empty_parse(monkeypatch):
    """1回だけパース0件のページがあっても、後続ページの取得を継続する。

    botブロック・一時的な空ページで残ページ全件を取りこぼさないこと
    （livable の EMPTY_PARSE_TOLERANCE と同じフェイルセーフ）。
    """
    from suumo_scraper import _scrape_ward

    row1 = _make_listing(url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_00000001/")
    row3 = _make_listing(url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_00000003/")
    _setup_scrape_ward(monkeypatch, [[row1], [], [row3]])

    results = _scrape_ward("koto", False, 10, None, None)

    urls = {r.url for r in results}
    assert row1.url in urls
    assert row3.url in urls, "空ページ1回で打ち切られ、後続ページが取りこぼされている"


def test_scrape_ward_stops_after_consecutive_empty_parses(monkeypatch):
    """連続でパース0件が続いた場合は許容回数で停止する（無限リクエスト防止）。"""
    from suumo_scraper import _scrape_ward, SUUMO_EMPTY_PARSE_TOLERANCE

    row1 = _make_listing(url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_00000001/")
    calls = _setup_scrape_ward(monkeypatch, [[row1]])

    results = _scrape_ward("koto", False, 50, None, None)

    assert [r.url for r in results] == [row1.url]
    # ページ1（成功） + 連続空ページ（許容回数ぶん）で停止
    assert calls["fetch"] == 1 + SUUMO_EMPTY_PARSE_TOLERANCE


# ---------- パース失敗の可観測性 ----------


def test_parse_list_html_logs_unit_parse_failures(monkeypatch, caplog):
    """_parse_suumo_unit が例外で None を返した件数が warning ログに集計される。

    HTML構造変更でパースが落ち始めたことを検知できるようにする
    （従来は except Exception: return None でサイレントに握り潰されていた）。
    """
    import logging
    import suumo_scraper

    html = (
        '<html><body>'
        '<div class="property_unit-content">a</div>'
        '<div class="property_unit-content">b</div>'
        '</body></html>'
    )
    monkeypatch.setattr(suumo_scraper, "_parse_suumo_unit", lambda *_a, **_kw: None)
    monkeypatch.setattr(suumo_scraper, "_parse_cassette", lambda *_a, **_kw: None)
    monkeypatch.setattr(suumo_scraper, "_parse_fallback", lambda *_a, **_kw: [])

    # 共通ロガーは propagate=False のため、caplog で拾えるよう一時的に伝播させる
    monkeypatch.setattr(logging.getLogger("realestate"), "propagate", True)
    with caplog.at_level(logging.WARNING, logger="realestate.suumo_scraper"):
        result = suumo_scraper.parse_list_html(html)

    assert result == []
    assert any("2/2" in rec.message for rec in caplog.records), \
        "パース失敗件数の集計ログが出ていない"


def test_parse_suumo_unit_exception_returns_none_with_debug_log(caplog, monkeypatch):
    """_parse_suumo_unit は要素が壊れていても例外を外に漏らさず None を返す。"""
    import logging
    from suumo_scraper import _parse_suumo_unit

    monkeypatch.setattr(logging.getLogger("realestate"), "propagate", True)

    class _Broken:
        def find(self, *a, **kw):
            raise RuntimeError("boom")

        def get_text(self, *a, **kw):
            raise RuntimeError("boom")

    with caplog.at_level(logging.DEBUG, logger="realestate.suumo_scraper"):
        assert _parse_suumo_unit(_Broken(), "https://suumo.jp") is None
    assert any("parse" in rec.message.lower() or "パース" in rec.message
               for rec in caplog.records), "例外がログに残っていない"


# ---------- 空ページメトリクスのセマンティクス ----------


def test_scrape_ward_normal_end_does_not_record_empty_pages(monkeypatch):
    """正常なページネーション終端（末尾の連続空ページ）はメトリクスに記録しない。

    終端の空ページは毎ラン necessarily 発生するため、記録すると
    23区 × 許容回数 = 数十回の「正常値」が常時アラートになってしまう。
    """
    import scraper_metrics
    scraper_metrics.reset()
    from suumo_scraper import _scrape_ward

    row1 = _make_listing(url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_00000001/")
    _setup_scrape_ward(monkeypatch, [[row1]])

    _scrape_ward("koto", False, 50, None, None)

    metrics = scraper_metrics.get_all()
    assert metrics.get("suumo", {}).get("empty_pages", 0) == 0, \
        "正常終端の空ページが記録されている（誤アラートの温床）"
    scraper_metrics.reset()


def test_scrape_ward_mid_gap_records_empty_pages(monkeypatch):
    """ページ列の途中の空ページ（後続ページで復活）は異常としてメトリクスに記録する。"""
    import scraper_metrics
    scraper_metrics.reset()
    from suumo_scraper import _scrape_ward

    row1 = _make_listing(url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_00000001/")
    row3 = _make_listing(url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_00000003/")
    _setup_scrape_ward(monkeypatch, [[row1], [], [row3]])

    _scrape_ward("koto", False, 10, None, None)

    metrics = scraper_metrics.get_all()
    assert metrics.get("suumo", {}).get("empty_pages", 0) == 1, \
        "途中の空ページ（botブロックの兆候）が記録されていない"
    scraper_metrics.reset()


def test_scrape_ward_total_failure_records_empty_pages(monkeypatch):
    """区全体が0件のまま終了（全滅）は異常としてメトリクスに記録する。"""
    import scraper_metrics
    scraper_metrics.reset()
    from suumo_scraper import _scrape_ward

    _setup_scrape_ward(monkeypatch, [[]])

    _scrape_ward("koto", False, 50, None, None)

    metrics = scraper_metrics.get_all()
    assert metrics.get("suumo", {}).get("empty_pages", 0) >= 1, \
        "区全滅（最有力のbotブロックシグナル）が記録されていない"
    scraper_metrics.reset()


def test_scrape_ward_records_finish_reason(monkeypatch):
    """終端理由が scraper_metrics に記録される（正常終端 / 早期打ち切り / 取得例外）。"""
    import scraper_metrics
    from suumo_scraper import _scrape_ward, SUUMO_EMPTY_PARSE_TOLERANCE

    # 正常終端（連続空パースによる停止）
    scraper_metrics.reset()
    row1 = _make_listing(url="https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_00000001/")
    _setup_scrape_ward(monkeypatch, [[row1]] + [[]] * SUUMO_EMPTY_PARSE_TOLERANCE)
    _scrape_ward("koto", False, 10, None, None)
    assert scraper_metrics.get_all()["suumo"]["finish_reasons"] == {"completed": 1}

    # 取得例外 = fetch_error（残ページ放棄として異常終端扱い）
    scraper_metrics.reset()

    def _boom(session, p, ward_roman=None, filtered_base_url=None):
        raise RuntimeError("connection reset")

    monkeypatch.setattr("suumo_scraper.fetch_list_page", _boom)
    _scrape_ward("koto", False, 10, None, None)
    assert scraper_metrics.get_all()["suumo"]["finish_reasons"] == {"fetch_error": 1}
    assert any("fetch_error" in a for a in scraper_metrics.health_alerts())
    scraper_metrics.reset()
