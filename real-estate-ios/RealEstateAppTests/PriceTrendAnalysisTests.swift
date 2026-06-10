import Testing
import Foundation
@testable import RealEstateApp

@Suite("PriceTrendAnalysis")
struct PriceTrendAnalysisTests {

    private func entries(_ items: [(String, Int?)]) -> [Listing.PriceHistoryEntry] {
        items.map { Listing.PriceHistoryEntry(date: $0.0, price_man: $0.1) }
    }

    @Test("履歴1件以下は nil")
    func insufficientHistory() {
        #expect(PriceTrendAnalysis(history: entries([("2026-06-01", 5000)])) == nil)
        #expect(PriceTrendAnalysis(history: []) == nil)
    }

    @Test("値下げ回数と累計変動率")
    func dropCountAndPct() throws {
        let analysis = try #require(PriceTrendAnalysis(history: entries([
            ("2026-04-01", 10000),
            ("2026-05-01", 9500),
            ("2026-06-01", 9000),
        ])))
        #expect(analysis.dropCount == 2)
        #expect(analysis.raiseCount == 0)
        #expect(abs((analysis.totalChangePct ?? 0) - (-10.0)) < 0.01)
    }

    @Test("急速値下げ判定（平均間隔14日以内）")
    func rapidDiscount() throws {
        let analysis = try #require(PriceTrendAnalysis(history: entries([
            ("2026-06-01", 10000),
            ("2026-06-08", 9500),
            ("2026-06-15", 9000),
        ])))
        #expect(analysis.avgDaysBetweenChanges == 7)
        #expect(analysis.trend == .rapidDiscount)
    }

    @Test("段階的値下げ判定（間隔が緩やか）")
    func gradualDiscount() throws {
        let analysis = try #require(PriceTrendAnalysis(history: entries([
            ("2026-01-01", 10000),
            ("2026-03-01", 9500),
            ("2026-06-01", 9000),
        ])))
        #expect((analysis.avgDaysBetweenChanges ?? 0) > PriceTrendAnalysis.rapidIntervalDays)
        #expect(analysis.trend == .gradualDiscount)
    }

    @Test("値上げ傾向")
    func increased() throws {
        let analysis = try #require(PriceTrendAnalysis(history: entries([
            ("2026-05-01", 9000),
            ("2026-06-01", 9500),
        ])))
        #expect(analysis.trend == .increased)
        #expect(analysis.raiseCount == 1)
    }

    @Test("値動きなし（同額継続）")
    func stable() throws {
        let analysis = try #require(PriceTrendAnalysis(history: entries([
            ("2026-05-01", 9000),
            ("2026-06-01", 9000),
        ])))
        #expect(analysis.trend == .stable)
        #expect(analysis.dropCount == 0)
    }

    @Test("上下混在")
    func mixed() throws {
        let analysis = try #require(PriceTrendAnalysis(history: entries([
            ("2026-04-01", 9000),
            ("2026-05-01", 8500),
            ("2026-06-01", 9200),
        ])))
        #expect(analysis.trend == .mixed)
    }

    @Test("price_man が nil のエントリは無視される")
    func nilPricesIgnored() throws {
        let analysis = try #require(PriceTrendAnalysis(history: entries([
            ("2026-04-01", 10000),
            ("2026-05-01", nil),
            ("2026-06-01", 9000),
        ])))
        #expect(analysis.dropCount == 1)
    }
}
