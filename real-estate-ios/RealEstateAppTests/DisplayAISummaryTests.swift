import Testing
import Foundation
@testable import RealEstateApp

@Suite("Listing.displayAISummary")
struct DisplayAISummaryTests {

    private func makeListing(
        investmentSummary: String? = nil,
        aiRecommendationSummary: String? = nil
    ) -> Listing {
        Listing(
            source: "test",
            url: "https://example.com/\(UUID().uuidString)",
            name: "テスト物件",
            investmentSummary: investmentSummary,
            aiRecommendationSummary: aiRecommendationSummary
        )
    }

    @Test("ai_recommendation_summary があればそれを優先する")
    func prefersRecommendationSummary() {
        let listing = makeListing(
            investmentSummary: "{\"flags\":[\"立地◎\"],\"score\":3,\"action\":\"指値\"}",
            aiRecommendationSummary: "立地は良いが62㎡はやや狭く、指値次第で検討余地。"
        )
        #expect(listing.displayAISummary == "立地は良いが62㎡はやや狭く、指値次第で検討余地。")
    }

    @Test("生JSONの investment_summary は表示しない")
    func ignoresRawJSONInvestmentSummary() {
        let listing = makeListing(
            investmentSummary: "{\"flags\":[\"立地◎\"],\"score\":3,\"action\":\"指値\"}",
            aiRecommendationSummary: nil
        )
        #expect(listing.displayAISummary == nil)
    }

    @Test("配列形式の生JSONも表示しない")
    func ignoresRawJSONArray() {
        let listing = makeListing(
            investmentSummary: "[\"立地◎\",\"価格やや高\"]",
            aiRecommendationSummary: nil
        )
        #expect(listing.displayAISummary == nil)
    }

    @Test("クリーンな legacy investment_summary はフォールバックとして表示する")
    func usesCleanLegacySummary() {
        let listing = makeListing(
            investmentSummary: "駅近で資産性が安定したファミリー向け物件。",
            aiRecommendationSummary: nil
        )
        #expect(listing.displayAISummary == "駅近で資産性が安定したファミリー向け物件。")
    }

    @Test("両方 nil なら nil")
    func bothNil() {
        let listing = makeListing(investmentSummary: nil, aiRecommendationSummary: nil)
        #expect(listing.displayAISummary == nil)
    }

    @Test("空文字・空白のみは表示しない")
    func emptyOrWhitespace() {
        let listing = makeListing(
            investmentSummary: "   ",
            aiRecommendationSummary: "   "
        )
        #expect(listing.displayAISummary == nil)
    }

    @Test("looksLikeRawJSON は { または [ 始まりを検出する（先頭空白も無視）")
    func looksLikeRawJSONDetection() {
        #expect(Listing.looksLikeRawJSON("{\"a\":1}"))
        #expect(Listing.looksLikeRawJSON("[1,2,3]"))
        #expect(Listing.looksLikeRawJSON("  {\"a\":1}"))
        #expect(Listing.looksLikeRawJSON("\n[1,2,3]"))
        #expect(!Listing.looksLikeRawJSON("駅近の物件"))
        #expect(!Listing.looksLikeRawJSON("   "))
        #expect(!Listing.looksLikeRawJSON(""))
    }
}
