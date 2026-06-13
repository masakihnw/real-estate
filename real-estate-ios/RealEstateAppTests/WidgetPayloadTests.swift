import Testing
import Foundation
@testable import RealEstateApp

@Suite("WidgetPayload JSON 互換")
struct WidgetPayloadTests {

    private func sample(featured: [WidgetPayload.Featured], brief: String?) -> WidgetPayload {
        WidgetPayload(
            totalListings: 120,
            newListings: 4,
            likedCount: 9,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            priceChanges: 0,
            likedSummaries: [.init(name: "物件A", priceMan: 8_000, priceChange: -200)],
            featuredItems: featured,
            briefText: brief
        )
    }

    @Test("featured + brief を含む往復で値が保たれる")
    func roundTripWithFeatured() throws {
        let featured = WidgetPayload.Featured(
            url: "https://x/1", name: "渋谷タワー 12F", priceText: "9,800万円",
            gradeLetter: "A", isNew: true, imageFileName: "featured-abc.jpg"
        )
        let data = try JSONEncoder().encode(sample(featured: [featured], brief: "新着4件。広尾が値下げ。"))
        let decoded = try JSONDecoder().decode(WidgetPayload.self, from: data)

        #expect(decoded.totalListings == 120)
        #expect(decoded.briefText == "新着4件。広尾が値下げ。")
        #expect(decoded.featuredItems?.count == 1)
        #expect(decoded.featuredItems?.first?.url == "https://x/1")
        #expect(decoded.featuredItems?.first?.gradeLetter == "A")
        #expect(decoded.featuredItems?.first?.imageFileName == "featured-abc.jpg")
        #expect(decoded.likedSummaries.first?.priceChange == -200)
    }

    @Test("featured 空・brief nil でも往復できる")
    func roundTripEmpty() throws {
        let data = try JSONEncoder().encode(sample(featured: [], brief: nil))
        let decoded = try JSONDecoder().decode(WidgetPayload.self, from: data)
        #expect(decoded.featuredItems?.isEmpty == true)
        #expect(decoded.briefText == nil)
    }

    @Test("旧 JSON（featuredItems/briefText キー欠落）でも decode 成功し nil になる")
    func decodesLegacyJSONWithoutNewKeys() throws {
        let legacy = """
        {"totalListings":50,"newListings":2,"likedCount":3,
         "lastUpdated":700000000,"priceChanges":0,"likedSummaries":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WidgetPayload.self, from: legacy)
        #expect(decoded.totalListings == 50)
        #expect(decoded.featuredItems == nil)
        #expect(decoded.briefText == nil)
    }

    @Test("WidgetImageStore のファイル名は同一 URL で安定・別 URL で異なる")
    func imageFileNameStability() {
        let a1 = WidgetImageStore.fileName(forListingURL: "https://x/1")
        let a2 = WidgetImageStore.fileName(forListingURL: "https://x/1")
        let b = WidgetImageStore.fileName(forListingURL: "https://x/2")
        #expect(a1 == a2)
        #expect(a1 != b)
        #expect(a1.hasPrefix("featured-"))
        #expect(a1.hasSuffix(".jpg"))
    }
}
