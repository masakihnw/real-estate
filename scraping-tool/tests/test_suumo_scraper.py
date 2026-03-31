"""suumo_scraper の主要ヘルパーのテスト。"""
from suumo_scraper import (
    SuumoListing,
    _is_tower_name,
    _snap_kt_server,
    apply_conditions,
    parse_suumo_detail_html,
)


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
