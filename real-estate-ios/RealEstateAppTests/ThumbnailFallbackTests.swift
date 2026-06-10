import Testing
import Foundation
@testable import RealEstateApp

/// 一覧カードサムネのフォールバックチェーンのテスト。
///
/// bestThumbnailURL は Routine②（毎日1回のAI画像分析）が設定するため、
/// 新着物件は最大約24時間未設定になる。その間 listings_feed_light の
/// first_image_url で画像を出す（プレースホルダ表示の解消）。
@Suite("Thumbnail Fallback")
struct ThumbnailFallbackTests {

    private func makeListing(
        bestThumbnailURL: String? = nil,
        firstImageURL: String? = nil,
        suumoImagesJSON: String? = nil
    ) -> Listing {
        Listing(
            source: "test",
            url: "https://example.com/1",
            name: "テスト物件",
            suumoImagesJSON: suumoImagesJSON,
            bestThumbnailURL: bestThumbnailURL,
            firstImageURL: firstImageURL
        )
    }

    @Test("bestThumbnailURL が最優先")
    func bestThumbnailWins() {
        let listing = makeListing(
            bestThumbnailURL: "https://img.example.com/best.jpg",
            firstImageURL: "https://img.example.com/fallback.jpg"
        )
        #expect(listing.thumbnailURL?.absoluteString == "https://img.example.com/best.jpg")
    }

    @Test("best 未設定なら firstImageURL にフォールバック（軽量フィードの新着物件）")
    func fallsBackToFirstImageURL() {
        let listing = makeListing(firstImageURL: "https://img.example.com/fallback.jpg")
        #expect(listing.thumbnailURL?.absoluteString == "https://img.example.com/fallback.jpg")
    }

    @Test("詳細取得済みなら画像配列（外観優先）が firstImageURL より優先")
    func parsedImagesBeatServerFallback() {
        let json = """
        [{"url":"https://img.example.com/living.jpg","label":"リビング"},
         {"url":"https://img.example.com/gaikan.jpg","label":"外観"}]
        """
        let listing = makeListing(
            firstImageURL: "https://img.example.com/fallback.jpg",
            suumoImagesJSON: json
        )
        #expect(listing.thumbnailURL?.absoluteString == "https://img.example.com/gaikan.jpg")
    }

    @Test("全部未設定なら nil（プレースホルダ表示）")
    func allMissingReturnsNil() {
        #expect(makeListing().thumbnailURL == nil)
    }

    @Test("firstImageURL が不正なURLでもクラッシュしない")
    func invalidFallbackURL() {
        let listing = makeListing(firstImageURL: "")
        #expect(listing.thumbnailURL == nil)
    }

    @Test("画像配列が空配列（\"[]\"）なら firstImageURL にフォールバック")
    func emptyImagesArrayFallsBack() {
        let listing = makeListing(
            firstImageURL: "https://img.example.com/fallback.jpg",
            suumoImagesJSON: "[]"
        )
        #expect(listing.thumbnailURL?.absoluteString == "https://img.example.com/fallback.jpg")
    }
}
