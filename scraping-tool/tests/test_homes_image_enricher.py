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


FEATURE_TAGS_HTML = """
<html><body>
<section>
  <ul class="mt-2 grid grid-cols-2">
    <li class="list-dot-brand">システムキッチン</li>
    <li class="list-dot-brand">バス・トイレ別</li>
    <li class="list-dot-brand">エレベーター</li>
    <li class="list-dot-brand">駐車場あり</li>
    <li class="list-dot-brand">システムキッチン</li>
  </ul>
</section>
</body></html>
"""


class TestParseHomesFeatureTags:
    def test_extracts_feature_tags(self):
        from floor_plan_enricher import parse_homes_feature_tags

        result = parse_homes_feature_tags(FEATURE_TAGS_HTML)
        assert result == [
            "システムキッチン",
            "バス・トイレ別",
            "エレベーター",
            "駐車場あり",
        ]

    def test_deduplicates_tags(self):
        from floor_plan_enricher import parse_homes_feature_tags

        result = parse_homes_feature_tags(FEATURE_TAGS_HTML)
        assert result.count("システムキッチン") == 1

    def test_empty_when_no_tags(self):
        from floor_plan_enricher import parse_homes_feature_tags

        assert parse_homes_feature_tags(MINIMAL_HTML) == []

    def test_respects_limit(self):
        from floor_plan_enricher import parse_homes_feature_tags

        items = "".join(
            f'<li class="list-dot-brand">タグ{i}</li>' for i in range(100)
        )
        html = f"<html><body><ul>{items}</ul></body></html>"
        result = parse_homes_feature_tags(html)
        assert len(result) == 60


class TestNeedsFeatureTags:
    def test_homes_without_feature_tags(self):
        from floor_plan_enricher import _needs_feature_tags

        listing = {"source": "homes", "url": "https://www.homes.co.jp/mansion/b-1/"}
        assert _needs_feature_tags(listing) is True

    def test_homes_with_empty_feature_tags(self):
        from floor_plan_enricher import _needs_feature_tags

        listing = {
            "source": "homes",
            "url": "https://www.homes.co.jp/mansion/b-1/",
            "feature_tags": [],
        }
        assert _needs_feature_tags(listing) is True

    def test_homes_with_feature_tags(self):
        from floor_plan_enricher import _needs_feature_tags

        listing = {
            "source": "homes",
            "url": "https://www.homes.co.jp/mansion/b-1/",
            "feature_tags": ["エレベーター"],
        }
        assert _needs_feature_tags(listing) is False

    def test_non_homes_listing(self):
        from floor_plan_enricher import _needs_feature_tags

        listing = {"source": "suumo", "url": "https://suumo.jp/ms/123/"}
        assert _needs_feature_tags(listing) is False

    def test_missing_url(self):
        from floor_plan_enricher import _needs_feature_tags

        assert _needs_feature_tags({"source": "homes"}) is False

    def test_not_a_dict(self):
        from floor_plan_enricher import _needs_feature_tags

        assert _needs_feature_tags("x") is False
        assert _needs_feature_tags(None) is False


# ──────────────────────────── HomesDetailFetcher のテスト ────────────────────────────

from types import SimpleNamespace

import floor_plan_enricher as fpe


class _FakeResponse:
    def __init__(self, text: str, status_code: int = 200):
        self.text = text
        self.status_code = status_code
        self.apparent_encoding = "utf-8"
        self.encoding = "utf-8"
        self.headers = {}

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


class TestHomesDetailFetcher:
    def _make(self, monkeypatch, cached=None, response=None, has_playwright=False):
        monkeypatch.setattr(fpe, "HAS_PLAYWRIGHT", has_playwright)
        monkeypatch.setattr(fpe, "_load_manifest", lambda: {})
        monkeypatch.setattr(fpe, "_read_cached_html", lambda url, m: cached)
        writes: list[tuple[str, str]] = []
        monkeypatch.setattr(
            fpe, "_write_html_cache", lambda url, html, m: writes.append((url, html)))
        if response is not None:
            fake_session = SimpleNamespace(get=lambda url, timeout=None: response)
            monkeypatch.setattr(fpe, "create_session", lambda: fake_session)
        fetcher = fpe.HomesDetailFetcher(delay_sec=0)
        return fetcher, writes

    def test_cache_hit_returns_without_fetch(self, monkeypatch):
        fetcher, writes = self._make(monkeypatch, cached="<html>cached</html>")
        # フェッチ経路が呼ばれたら失敗させる
        monkeypatch.setattr(
            fetcher, "_fetch_requests",
            lambda url: (_ for _ in ()).throw(AssertionError("fetch called")))

        html, from_cache = fetcher.fetch("https://www.homes.co.jp/mansion/b-1/")
        assert html == "<html>cached</html>"
        assert from_cache is True
        assert writes == []

    def test_requests_success_writes_cache(self, monkeypatch):
        body = "<html><body>" + "x" * 2000 + "</body></html>"
        fetcher, writes = self._make(monkeypatch, response=_FakeResponse(body))

        html, from_cache = fetcher.fetch("https://www.homes.co.jp/mansion/b-1/")
        assert html == body
        assert from_cache is False
        assert len(writes) == 1

    def test_waf_challenge_returns_none_without_retry_or_cache(self, monkeypatch):
        """WAFチャレンジは待機リトライせず即 None（旧実装は最大7.5分/URL浪費）。"""
        waf_html = "<html>awsWafCookieDomainList</html>"  # is_waf_challenge が真になる
        fetcher, writes = self._make(monkeypatch, response=_FakeResponse(waf_html))

        html, from_cache = fetcher.fetch("https://www.homes.co.jp/mansion/b-1/")
        assert html is None
        assert from_cache is False
        assert writes == [], "WAFチャレンジページがキャッシュされている"

    def test_http_error_returns_none(self, monkeypatch):
        fetcher, writes = self._make(monkeypatch, response=_FakeResponse("err", status_code=503))

        html, _ = fetcher.fetch("https://www.homes.co.jp/mansion/b-1/")
        assert html is None
        assert writes == []

    def test_close_without_open_is_safe(self, monkeypatch):
        fetcher, _ = self._make(monkeypatch)
        fetcher.close()  # 例外が出ないこと
