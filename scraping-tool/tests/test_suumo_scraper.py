"""suumo_scraper の parse_suumo_detail_html のテスト。"""
from suumo_scraper import _snap_kt_server, parse_suumo_detail_html


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
