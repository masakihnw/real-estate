import Testing
import Foundation
@testable import RealEstateApp

/// image_categories の2形式（object形 / array形）パースのテスト。
///
/// 詳細画面の物件写真ギャラリーは parsedImageCategories を使う。
/// claude_image_analyzer は array形 [{url,label,category,...}] を出力する一方、
/// 旧ポータル画像は object形 {"exterior":[...]} で保存されている。
/// 両形式をパースできないと詳細画像が表示されない（実際に発生した不具合の回帰防止）。
@Suite("ImageCategories Parsing")
struct ImageCategoriesParsingTests {

    private func makeListing(imageCategoriesJSON: String?) -> Listing {
        Listing(
            source: "test",
            url: "https://example.com/1",
            name: "テスト物件",
            imageCategoriesJSON: imageCategoriesJSON
        )
    }

    @Test("array形（R2 URL・category 付き）をカテゴリ別にパースする")
    func parsesArrayForm() {
        let json = """
        [
          {"url": "https://pub-x.r2.dev/property_images/a.jpg", "label": "外観", "category": "exterior", "is_junk": false, "quality_score": 0.8, "brief_description": "現地外観"},
          {"url": "https://pub-x.r2.dev/property_images/b.jpg", "label": "眺望", "category": "view", "is_junk": false, "quality_score": 0.9, "brief_description": "住戸からの眺望"},
          {"url": "https://pub-x.r2.dev/property_images/c.jpg", "label": "リビング", "category": "interior", "is_junk": false}
        ]
        """
        let groups = makeListing(imageCategoriesJSON: json).parsedImageCategories
        // 定義順（exterior → interior → view）に並ぶ
        #expect(groups.map(\.category) == ["exterior", "interior", "view"])
        let exterior = groups.first { $0.category == "exterior" }
        #expect(exterior?.images.first?.url == "https://pub-x.r2.dev/property_images/a.jpg")
        #expect(exterior?.images.first?.quality == 0.8)
        #expect(exterior?.images.first?.description == "現地外観")
    }

    @Test("array形の is_junk=true は除外する")
    func arrayFormExcludesJunk() {
        let json = """
        [
          {"url": "https://pub-x.r2.dev/property_images/keep.jpg", "category": "exterior", "is_junk": false},
          {"url": "https://pub-x.r2.dev/property_images/junk.jpg", "category": "exterior", "is_junk": true}
        ]
        """
        let groups = makeListing(imageCategoriesJSON: json).parsedImageCategories
        #expect(groups.count == 1)
        #expect(groups.first?.images.count == 1)
        #expect(groups.first?.images.first?.url.hasSuffix("keep.jpg") == true)
    }

    @Test("object形（カテゴリキー辞書）も引き続きパースする")
    func parsesObjectForm() {
        let json = """
        {"exterior": [{"url": "https://img.example.com/e.jpg", "label": "外観", "quality": 0.5, "description": ""}],
         "view": [{"url": "https://img.example.com/v.jpg", "label": "眺望"}]}
        """
        let groups = makeListing(imageCategoriesJSON: json).parsedImageCategories
        #expect(groups.map(\.category) == ["exterior", "view"])
        #expect(groups.first?.images.first?.url == "https://img.example.com/e.jpg")
    }

    @Test("未知カテゴリ（other）も末尾に保持し、ラベルは『その他』")
    func keepsUnknownCategory() {
        let json = """
        [{"url": "https://pub-x.r2.dev/property_images/o.jpg", "category": "other"}]
        """
        let groups = makeListing(imageCategoriesJSON: json).parsedImageCategories
        #expect(groups.count == 1)
        #expect(groups.first?.category == "other")
        #expect(groups.first?.localizedCategory == "その他")
    }

    @Test("nil / 空 / 不正 JSON は空配列")
    func handlesEmptyAndInvalid() {
        #expect(makeListing(imageCategoriesJSON: nil).parsedImageCategories.isEmpty)
        #expect(makeListing(imageCategoriesJSON: "[]").parsedImageCategories.isEmpty)
        #expect(makeListing(imageCategoriesJSON: "not json").parsedImageCategories.isEmpty)
    }
}
