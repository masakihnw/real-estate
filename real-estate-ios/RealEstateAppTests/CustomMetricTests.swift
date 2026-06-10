import Testing
import Foundation
@testable import RealEstateApp

@Suite("CustomMetric")
struct CustomMetricTests {

    private func makeListing(
        priceFairness: Int? = nil,
        resaleLiquidity: Int? = nil,
        listingScore: Int? = nil,
        walkMin: Int? = nil,
        aiScore: Int? = nil
    ) -> Listing {
        let listing = Listing(
            source: "test",
            url: "https://example.com/\(UUID().uuidString)",
            name: "テスト物件",
            walkMin: walkMin
        )
        listing.priceFairnessScore = priceFairness
        listing.resaleLiquidityScore = resaleLiquidity
        listing.listingScore = listingScore
        listing.aiRecommendationScore = aiScore
        return listing
    }

    @Test("全コンポーネント揃いの加重平均")
    func fullComponents() throws {
        var metric = CustomMetric()
        metric.weightPriceFairness = 0.5
        metric.weightResaleLiquidity = 0.5
        metric.weightListingScore = 0
        metric.weightWalkConvenience = 0
        metric.weightAIRecommendation = 0

        let listing = makeListing(priceFairness: 80, resaleLiquidity: 60)
        let score = try #require(metric.score(for: listing))
        #expect(abs(score - 70) < 0.01)
    }

    @Test("欠損コンポーネントは除外して再正規化")
    func missingComponentsRenormalized() throws {
        var metric = CustomMetric()
        metric.weightPriceFairness = 0.5
        metric.weightResaleLiquidity = 0.5
        metric.weightListingScore = 0
        metric.weightWalkConvenience = 0
        metric.weightAIRecommendation = 0

        // resaleLiquidity 欠損 → priceFairness のみで評価
        let listing = makeListing(priceFairness: 80)
        let score = try #require(metric.score(for: listing))
        #expect(abs(score - 80) < 0.01)
    }

    @Test("データが何もなければ nil")
    func noComponents() {
        let metric = CustomMetric()
        #expect(metric.score(for: makeListing()) == nil)
    }

    @Test("徒歩分数の変換: 0分=100点、20分以上=0点")
    func walkScoreConversion() throws {
        var metric = CustomMetric()
        metric.weightPriceFairness = 0
        metric.weightResaleLiquidity = 0
        metric.weightListingScore = 0
        metric.weightWalkConvenience = 1.0
        metric.weightAIRecommendation = 0

        let near = try #require(metric.score(for: makeListing(walkMin: 0)))
        #expect(abs(near - 100) < 0.01)
        let mid = try #require(metric.score(for: makeListing(walkMin: 10)))
        #expect(abs(mid - 50) < 0.01)
        let far = try #require(metric.score(for: makeListing(walkMin: 25)))
        #expect(far == 0)
    }

    @Test("AI推奨度の変換: 1→0点、5→100点")
    func aiScoreConversion() throws {
        var metric = CustomMetric()
        metric.weightPriceFairness = 0
        metric.weightResaleLiquidity = 0
        metric.weightListingScore = 0
        metric.weightWalkConvenience = 0
        metric.weightAIRecommendation = 1.0

        #expect(try #require(metric.score(for: makeListing(aiScore: 1))) == 0)
        #expect(try #require(metric.score(for: makeListing(aiScore: 5))) == 100)
    }

    @Test("保存と読み込みのラウンドトリップ")
    func saveLoadRoundtrip() {
        let suiteName = "CustomMetricTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var metric = CustomMetric()
        metric.weightPriceFairness = 0.7
        metric.save(to: defaults)

        let loaded = CustomMetric.load(from: defaults)
        #expect(loaded == metric)
    }

    @Test("未保存ならデフォルト値")
    func loadDefault() {
        let suiteName = "CustomMetricTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(CustomMetric.load(from: defaults) == CustomMetric())
    }
}
