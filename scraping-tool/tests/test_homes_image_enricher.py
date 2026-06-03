"""HOME'S 画像エンリッチャーのユニットテスト。"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


SAMPLE_DETAIL_HTML = """
<html><body>
<div class="image-gallery-carousel">
  <img src="https://image4.homes.jp/smallimg/image.php?file=%2Fdata%2F1600017%2Fsale%2Fimage%2F0000322-1.jpg&height=504"
       alt="テストマンション 外観">
  <img src="https://image1.homes.jp/data/1600017/premium/image/16000170000322_1_1.jpg?modify_date=123&height=504"
       alt="テストマンション コンセプト">
  <img src="https://image.homes.jp/smallimg/image.php?file=%2Fdata%2F1600017%2Fsale%2Fimage%2F0000322_gold_lib2-1.jpg&height=504"
       alt="テストマンション 専有部">
</div>
<div id="floorplan">
  <img src="https://image3.homes.jp/smallimg/image.php?file=%2Fdata%2F1600017%2Fsale%2Fimage%2F0000322_madori-1.png&width=425"
       alt="テストマンション 間取り F">
</div>
<div>
  <img src="https://image4.homes.jp/smallimg/image.php?file=%2Fdata%2F1600017%2Fsale%2Fimage%2F0000322_gold_ame-1.jpg"
       alt="テストマンション デリシアコンロ">
  <img src="https://image3.homes.jp/smallimg/image.php?file=%2Fdata%2F1600017%2Fsale%2Fimage%2F0000322_gold_surr-1.jpg"
       alt="周辺環境">
</div>
<!-- UI / non-property images -->
<img src="/search/assets/img/default/page/detail/mansion/homes-kun-1@2x.png" alt="">
<img src="https://www.homes.co.jp/common/img/logo.png" alt="HOME'S ロゴ">
<img src="data:image/gif;base64,AAAA" alt="spacer">
<!-- Duplicate of first image with different size params -->
<img src="https://image4.homes.jp/smallimg/image.php?file=%2Fdata%2F1600017%2Fsale%2Fimage%2F0000322-1.jpg&width=898&height=500"
     alt="テストマンション 外観">
</body></html>
"""

MINIMAL_HTML = """<html><body><p>物件が見つかりません</p></body></html>"""

FLOOR_PLAN_ONLY_HTML = """
<html><body>
<img src="https://image3.homes.jp/smallimg/image.php?file=%2Fdata%2F100%2Fsale%2Fimage%2F001_madori-1.png"
     alt="テスト 間取り">
<img src="https://image.homes.jp/smallimg/image.php?file=%2Fdata%2F100%2Fsale%2Fimage%2F001_madori-2.png"
     alt="テスト 間取り 2F">
</body></html>
"""


class TestParseHomesPropertyImages:
    def test_extracts_property_images_and_excludes_floor_plans(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(SAMPLE_DETAIL_HTML)
        urls = [img["url"] for img in result]
        labels = [img["label"] for img in result]

        assert len(result) >= 4
        assert all("homes.jp" in url for url in urls)
        assert not any("_madori" in url for url in urls)
        assert not any("間取" in label for label in labels)

    def test_excludes_ui_images(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(SAMPLE_DETAIL_HTML)
        urls = [img["url"] for img in result]

        assert not any("homes-kun" in url for url in urls)
        assert not any("/common/img/" in url for url in urls)
        assert not any(url.startswith("data:") for url in urls)

    def test_deduplicates_same_image_with_different_sizes(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(SAMPLE_DETAIL_HTML)
        urls = [img["url"] for img in result]

        exterior_urls = [u for u in urls if "0000322-1" in u]
        assert len(exterior_urls) == 1

    def test_returns_empty_list_for_no_images(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(MINIMAL_HTML)
        assert result == []

    def test_returns_empty_when_only_floor_plans(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(FLOOR_PLAN_ONLY_HTML)
        assert result == []

    def test_label_uses_alt_text(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(SAMPLE_DETAIL_HTML)
        labels = {img["label"] for img in result}

        assert any("外観" in l for l in labels)
        assert any("専有部" in l for l in labels)

    def test_label_fallback_for_empty_alt(self):
        html = """<html><body>
        <img src="https://image1.homes.jp/smallimg/image.php?file=%2Fdata%2F100%2Fsale%2Fimage%2F001-1.jpg"
             alt="">
        </body></html>"""
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(html)
        assert len(result) == 1
        assert result[0]["label"] == "外観"


CHUKO_DETAIL_HTML = """
<html><body>
<div id="main">
  <img src="https://image1.homes.jp/smallimg/image.php?file=http%3A%2F%2Fimg.homes.jp%2F121639%2Fsale%2F38128%2F1%2F2%2Fh9dm.jpg&width=600"
       alt="物件画像">
  <img src="https://image1.homes.jp/smallimg/image.php?file=http%3A%2F%2Fimg.homes.jp%2F121639%2Fsale%2F38128%2F1%2F2%2Fh9dm.jpg&width=600"
       alt="間取りを拡大表示">
</div>
<!-- related listings in splide carousel -->
<div class="splide">
  <div class="splide__list">
    <a class="splide__slide">
      <img src="https://image4.homes.jp/smallimg/image.php?file=http%3A%2F%2Fimg.homes.jp%2F149704%2Fsale%2F25%2F2%2Fimage.jpg"
           alt="サンウッドウエリス品川御殿山">
      <img src="https://image2.homes.jp/smallimg/image.php?file=http%3A%2F%2Fimg.homes.jp%2F155375%2Fsale%2F10%2F2%2Fimage.jpg"
           alt="セザールパークサイド南大井">
    </a>
  </div>
</div>
</body></html>
"""


class TestParseHomesPropertyImagesChuko:
    def test_extracts_chuko_property_image(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(CHUKO_DETAIL_HTML)
        assert len(result) == 1
        assert "121639" in result[0]["url"]
        assert result[0]["label"] == "物件画像"

    def test_excludes_related_listings_in_splide(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(CHUKO_DETAIL_HTML)
        urls = [img["url"] for img in result]
        assert not any("149704" in u for u in urls)
        assert not any("155375" in u for u in urls)

    def test_excludes_floor_plan_by_alt(self):
        from floor_plan_enricher import parse_homes_property_images

        result = parse_homes_property_images(CHUKO_DETAIL_HTML)
        labels = [img["label"] for img in result]
        assert not any("間取" in l for l in labels)


class TestNormalizeHomesImageUrl:
    def test_strips_size_params(self):
        from floor_plan_enricher import _normalize_homes_image_url

        url = "https://image4.homes.jp/smallimg/image.php?file=%2Fdata%2F100%2Fsale%2Fimage%2F001-1.jpg&width=898&height=500"
        normalized = _normalize_homes_image_url(url)
        assert "width=" not in normalized
        assert "height=" not in normalized
        assert "file=" in normalized

    def test_strips_modify_date(self):
        from floor_plan_enricher import _normalize_homes_image_url

        url = "https://image1.homes.jp/data/100/premium/image/123_1_1.jpg?modify_date=123&height=504"
        normalized = _normalize_homes_image_url(url)
        assert "modify_date" not in normalized
        assert "height" not in normalized

    def test_preserves_core_url(self):
        from floor_plan_enricher import _normalize_homes_image_url

        url = "https://image4.homes.jp/smallimg/image.php?file=%2Fdata%2F100%2Fsale%2Fimage%2F001-1.jpg"
        assert _normalize_homes_image_url(url) == url

    def test_returns_none_for_non_homes_url(self):
        from floor_plan_enricher import _normalize_homes_image_url

        assert _normalize_homes_image_url("/search/assets/img/logo.png") is None
        assert _normalize_homes_image_url("data:image/gif;base64,AAAA") is None
        assert _normalize_homes_image_url("") is None


class TestNeedsImageEnrichment:
    def test_homes_listing_without_images(self):
        from floor_plan_enricher import _needs_image_enrichment

        listing = {"source": "homes", "url": "https://www.homes.co.jp/mansion/b-123/"}
        assert _needs_image_enrichment(listing) is True

    def test_homes_listing_with_only_floor_plans(self):
        from floor_plan_enricher import _needs_image_enrichment

        listing = {
            "source": "homes",
            "url": "https://www.homes.co.jp/mansion/b-123/",
            "floor_plan_images": ["https://example.com/fp.jpg"],
        }
        assert _needs_image_enrichment(listing) is True

    def test_homes_listing_with_only_suumo_images(self):
        from floor_plan_enricher import _needs_image_enrichment

        listing = {
            "source": "homes",
            "url": "https://www.homes.co.jp/mansion/b-123/",
            "suumo_images": [{"url": "https://example.com/img.jpg", "label": "外観"}],
        }
        assert _needs_image_enrichment(listing) is True

    def test_homes_listing_with_both_images(self):
        from floor_plan_enricher import _needs_image_enrichment

        listing = {
            "source": "homes",
            "url": "https://www.homes.co.jp/mansion/b-123/",
            "floor_plan_images": ["https://example.com/fp.jpg"],
            "suumo_images": [{"url": "https://example.com/img.jpg", "label": "外観"}],
        }
        assert _needs_image_enrichment(listing) is False

    def test_non_homes_listing(self):
        from floor_plan_enricher import _needs_image_enrichment

        listing = {"source": "suumo", "url": "https://suumo.jp/ms/123/"}
        assert _needs_image_enrichment(listing) is False

    def test_missing_url(self):
        from floor_plan_enricher import _needs_image_enrichment

        listing = {"source": "homes"}
        assert _needs_image_enrichment(listing) is False

    def test_not_a_dict(self):
        from floor_plan_enricher import _needs_image_enrichment

        assert _needs_image_enrichment("not a dict") is False
        assert _needs_image_enrichment(None) is False
