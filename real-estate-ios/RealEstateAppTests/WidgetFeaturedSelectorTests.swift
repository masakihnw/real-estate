import Testing
import Foundation
@testable import RealEstateApp

@Suite("WidgetFeaturedSelector 今日の1枚の選定")
struct WidgetFeaturedSelectorTests {

    private nonisolated(unsafe) static var counter = 0

    private func makeListing(
        score: Int?,
        addedDaysAgo: Double = 1,
        isDelisted: Bool = false,
        priceMan: Int? = 8_000
    ) -> Listing {
        WidgetFeaturedSelectorTests.counter += 1
        let unique = "wf_\(WidgetFeaturedSelectorTests.counter)_\(UUID().uuidString.prefix(8))"
        let l = Listing(
            url: "https://test.example.com/\(unique)",
            name: unique,
            priceMan: priceMan,
            propertyType: "chuko",
            listingScore: score
        )
        l.addedAt = Date().addingTimeInterval(-addedDaysAgo * 24 * 3600)
        l.isDelisted = isDelisted
        return l
    }

    @Test("新着のうち listingScore 最高を選ぶ")
    func picksHighestScore() {
        let low = makeListing(score: 30)
        let high = makeListing(score: 90)
        let mid = makeListing(score: 60)
        let featured = WidgetFeaturedSelector.select(from: [low, high, mid])
        #expect(featured?.url == high.url)
        #expect(featured?.score == 90)
    }

    @Test("同点スコアは addedAt が新しい方を選ぶ")
    func tiebreakByRecency() {
        let older = makeListing(score: 50, addedDaysAgo: 2)
        let newer = makeListing(score: 50, addedDaysAgo: 0.2)
        let featured = WidgetFeaturedSelector.select(from: [older, newer])
        #expect(featured?.url == newer.url)
    }

    @Test("古い物件・掲載終了は除外")
    func excludesOldAndDelisted() {
        let old = makeListing(score: 99, addedDaysAgo: 10)
        let delisted = makeListing(score: 95, addedDaysAgo: 0, isDelisted: true)
        let fresh = makeListing(score: 40, addedDaysAgo: 0)
        let featured = WidgetFeaturedSelector.select(from: [old, delisted, fresh])
        #expect(featured?.url == fresh.url)
    }

    @Test("対象なしは nil")
    func nilWhenNoCandidates() {
        let old = makeListing(score: 99, addedDaysAgo: 10)
        #expect(WidgetFeaturedSelector.select(from: [old]) == nil)
        #expect(WidgetFeaturedSelector.select(from: []) == nil)
    }

    @Test("表示フィールドが Listing から転記される")
    func mapsDisplayFields() {
        let l = makeListing(score: 70, priceMan: 9_800)
        let featured = WidgetFeaturedSelector.select(from: [l])
        #expect(featured?.url == l.url)
        #expect(featured?.name == l.nameWithFloor)
        #expect(featured?.priceText == l.priceDisplayCompact)
        #expect(featured?.gradeLetter == l.scoreGradeLetter)
    }
}

@Suite("WidgetDeepLink URL 往復")
struct WidgetDeepLinkTests {

    @Test("listing.url から URL を組み立て、再び取り出せる")
    func roundTrip() {
        let listingURL = "https://suumo.jp/ms/chuko/tokyo/sc_minato/abc123/"
        let url = WidgetDeepLink.url(forListingURL: listingURL)
        #expect(url != nil)
        #expect(url?.scheme == "realestate")
        let parsed = WidgetDeepLink.listingURL(from: url!)
        #expect(parsed == listingURL)
    }

    @Test("クエリ・特殊文字を含む URL もエンコードされ復元される")
    func encodesSpecialChars() {
        let listingURL = "https://example.com/a?b=1&c=日本語"
        let url = WidgetDeepLink.url(forListingURL: listingURL)
        #expect(WidgetDeepLink.listingURL(from: url!) == listingURL)
    }

    @Test("スキーム違いは nil")
    func rejectsWrongScheme() {
        let url = URL(string: "https://listing?u=x")!
        #expect(WidgetDeepLink.listingURL(from: url) == nil)
    }

    @Test("host 違い・クエリ欠落は nil")
    func rejectsWrongHostOrMissingQuery() {
        #expect(WidgetDeepLink.listingURL(from: URL(string: "realestate://other?u=x")!) == nil)
        #expect(WidgetDeepLink.listingURL(from: URL(string: "realestate://listing")!) == nil)
        #expect(WidgetDeepLink.listingURL(from: URL(string: "realestate://listing?u=")!) == nil)
    }
}
