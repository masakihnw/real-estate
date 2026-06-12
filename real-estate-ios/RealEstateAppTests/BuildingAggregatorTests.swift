import Testing
import Foundation
@testable import RealEstateApp

@Suite("棟内ベスト戸の代表選定")
@MainActor
struct BuildingAggregatorTests {

    private func makeUnit(
        url: String,
        priceMan: Int? = nil,
        listingScore: Int? = nil,
        aiScore: Int? = nil
    ) -> Listing {
        let l = Listing(
            source: "test",
            url: url,
            name: "テストタワー"
        )
        l.priceMan = priceMan
        l.listingScore = listingScore
        l.aiRecommendationScore = aiScore
        return l
    }

    @Test("★（AI推奨度）が高い戸が優先される")
    func aiScoreWins() {
        let low = makeUnit(url: "u1", priceMan: 7000, listingScore: 90, aiScore: 3)
        let high = makeUnit(url: "u2", priceMan: 9000, listingScore: 50, aiScore: 5)
        #expect(BuildingAggregator.isBetter(high, than: low))
        #expect(!BuildingAggregator.isBetter(low, than: high))
        #expect(BuildingAggregator.bestRepresentative(from: [low, high])?.url == "u2")
    }

    @Test("★が同点なら listing_score が高い戸")
    func listingScoreTieBreak() {
        let a = makeUnit(url: "u1", priceMan: 8000, listingScore: 60, aiScore: 4)
        let b = makeUnit(url: "u2", priceMan: 8000, listingScore: 75, aiScore: 4)
        #expect(BuildingAggregator.bestRepresentative(from: [a, b])?.url == "u2")
    }

    @Test("★・listing_score 同点なら安い戸（棟内最安を代表）")
    func priceTieBreak() {
        let cheap = makeUnit(url: "u1", priceMan: 7800, listingScore: 70, aiScore: 4)
        let pricey = makeUnit(url: "u2", priceMan: 9200, listingScore: 70, aiScore: 4)
        #expect(BuildingAggregator.bestRepresentative(from: [cheap, pricey])?.url == "u1")
    }

    @Test("スコア未付与（nil）戸より、スコア付き戸が優先される")
    func nilScoresRankLast() {
        let scored = makeUnit(url: "u1", priceMan: 9000, listingScore: 55, aiScore: 3)
        let unscored = makeUnit(url: "u2", priceMan: 7000)
        #expect(BuildingAggregator.bestRepresentative(from: [unscored, scored])?.url == "u1")
    }

    @Test("全項目同点なら URL で決定的に決まる")
    func deterministicTieBreak() {
        let a = makeUnit(url: "aaa", priceMan: 8000, listingScore: 70, aiScore: 4)
        let b = makeUnit(url: "bbb", priceMan: 8000, listingScore: 70, aiScore: 4)
        // 入力順を入れ替えても代表は同じ（決定的）
        #expect(BuildingAggregator.bestRepresentative(from: [a, b])?.url == "aaa")
        #expect(BuildingAggregator.bestRepresentative(from: [b, a])?.url == "aaa")
    }

    @Test("空配列なら nil")
    func emptyReturnsNil() {
        #expect(BuildingAggregator.bestRepresentative(from: []) == nil)
    }
}
