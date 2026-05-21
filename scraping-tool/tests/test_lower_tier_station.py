"""下位ティア駅フィルタのテスト。"""
import pytest

from scraper_common import lower_tier_station_ok, _normalize_station_name


class TestNormalizeStationName:
    def test_remove_eki_suffix(self):
        assert _normalize_station_name("豊洲駅") == "豊洲"

    def test_normalize_small_ke(self):
        assert _normalize_station_name("市ヶ谷") == "市ケ谷"

    def test_no_change(self):
        assert _normalize_station_name("渋谷") == "渋谷"

    def test_strip_whitespace(self):
        assert _normalize_station_name("  池袋  ") == "池袋"


class TestLowerTierStationOk:
    """lower_tier_station_ok のテスト。"""

    def test_upper_tier_always_passes(self):
        assert lower_tier_station_ok("ＪＲ山手線「新小岩」徒歩5分", 9500) is True

    def test_upper_tier_boundary(self):
        assert lower_tier_station_ok("ＪＲ山手線「新小岩」徒歩5分", 9000) is True

    def test_none_price_passes(self):
        assert lower_tier_station_ok("ＪＲ山手線「新小岩」徒歩5分", None) is True

    def test_lower_tier_allowed_station(self):
        assert lower_tier_station_ok("東京メトロ有楽町線「豊洲」徒歩5分", 8500) is True

    def test_lower_tier_disallowed_station(self):
        assert lower_tier_station_ok("東京メトロ有楽町線「辰巳」徒歩5分", 8500) is False

    def test_lower_tier_jr_allowed(self):
        assert lower_tier_station_ok("ＪＲ総武線「亀戸」徒歩3分", 7800) is True

    def test_lower_tier_jr_disallowed(self):
        assert lower_tier_station_ok("ＪＲ総武線「平井」徒歩3分", 7800) is False

    def test_empty_station_line_passes(self):
        assert lower_tier_station_ok("", 8000) is True

    def test_lower_tier_ginza_浅草(self):
        assert lower_tier_station_ok("東京メトロ銀座線「浅草」徒歩4分", 8000) is True

    def test_lower_tier_ginza_beyond(self):
        """銀座線の浅草以遠（外苑前は含まれる）。"""
        assert lower_tier_station_ok("東京メトロ銀座線「外苑前」徒歩2分", 8500) is True

    def test_lower_tier_marunouchi_茗荷谷(self):
        assert lower_tier_station_ok("東京メトロ丸ノ内線「茗荷谷」徒歩6分", 8000) is True

    def test_lower_tier_marunouchi_beyond(self):
        """丸ノ内線の茗荷谷以遠（荻窪方面）は除外。"""
        assert lower_tier_station_ok("東京メトロ丸ノ内線「新高円寺」徒歩5分", 8000) is False

    def test_lower_tier_namboku_本駒込(self):
        assert lower_tier_station_ok("東京メトロ南北線「本駒込」徒歩7分", 8500) is True

    def test_lower_tier_namboku_beyond(self):
        """南北線の本駒込以遠（王子方面）は除外。"""
        assert lower_tier_station_ok("東京メトロ南北線「王子」徒歩4分", 8000) is False

    def test_lower_tier_chiyoda_千駄木(self):
        assert lower_tier_station_ok("東京メトロ千代田線「千駄木」徒歩3分", 8200) is True

    def test_lower_tier_chiyoda_beyond(self):
        """千代田線の千駄木以遠（北千住方面）は除外。"""
        assert lower_tier_station_ok("東京メトロ千代田線「町屋」徒歩5分", 8000) is False

    def test_lower_tier_mita_白山(self):
        assert lower_tier_station_ok("都営三田線「白山」徒歩2分", 7900) is True

    def test_lower_tier_mita_beyond(self):
        """三田線の白山以遠（板橋方面）は除外。"""
        assert lower_tier_station_ok("都営三田線「千石」徒歩3分", 7900) is False

    def test_lower_tier_tokyu_meguro_武蔵小山(self):
        assert lower_tier_station_ok("東急目黒線「武蔵小山」徒歩4分", 8800) is True

    def test_lower_tier_tokyu_meguro_beyond(self):
        """東急目黒線の武蔵小山以遠は除外。"""
        assert lower_tier_station_ok("東急目黒線「西小山」徒歩3分", 8800) is False

    def test_lower_tier_oedo_loop(self):
        assert lower_tier_station_ok("都営大江戸線「勝どき」徒歩5分", 8500) is True

    def test_lower_tier_oedo_tail_excluded(self):
        """大江戸線の光が丘方面テールは除外。"""
        assert lower_tier_station_ok("都営大江戸線「練馬」徒歩3分", 8000) is False

    def test_lower_tier_keihin_tohoku_大井町(self):
        assert lower_tier_station_ok("ＪＲ京浜東北線「大井町」徒歩6分", 8300) is True

    def test_lower_tier_keihin_tohoku_beyond(self):
        """京浜東北線の大井町以遠（大森方面）は除外。"""
        assert lower_tier_station_ok("ＪＲ京浜東北線「大森」徒歩4分", 8000) is False

    def test_ke_variant_matching(self):
        """市ヶ谷（小さいヶ）でも市ケ谷（大きいケ）として一致。"""
        assert lower_tier_station_ok("都営新宿線「市ヶ谷」徒歩1分", 8000) is True

    def test_price_at_lower_boundary(self):
        assert lower_tier_station_ok("東京メトロ有楽町線「豊洲」徒歩5分", 7500) is True

    def test_price_just_below_upper_tier(self):
        assert lower_tier_station_ok("東京メトロ有楽町線「辰巳」徒歩5分", 8999) is False
