import Testing
import Foundation
@testable import RealEstateApp

@Suite("Watchlist Price Drop Filtering")
struct WatchlistPriceDropTests {

    private func makeListing(
        isLiked: Bool = false,
        assetGrade: String? = nil,
        priceHistory: [(String, Int)] = []
    ) -> Listing {
        let json: String? = priceHistory.isEmpty ? nil : {
            let entries = priceHistory.map { "{\"date\":\"\($0.0)\",\"price_man\":\($0.1)}" }
            return "[\(entries.joined(separator: ","))]"
        }()
        return Listing(
            source: "test",
            url: "https://example.com/\(UUID().uuidString)",
            name: "テスト物件",
            isLiked: isLiked,
            priceHistoryJSON: json,
            assetGrade: assetGrade
        )
    }

    @Test("いいね物件の値下げは対象")
    func likedWithPriceDrop() {
        let listing = makeListing(
            isLiked: true,
            priceHistory: [("2026-06-01", 5000), ("2026-06-08", 4800)]
        )
        #expect(listing.latestPriceChange == -200)
        #expect(WatchlistFilter.priceDrops(in: [listing]).count == 1)
    }

    @Test("S評価物件の値下げは対象")
    func sGradeWithPriceDrop() {
        let listing = makeListing(
            assetGrade: "S",
            priceHistory: [("2026-06-01", 8000), ("2026-06-08", 7500)]
        )
        #expect(WatchlistFilter.priceDrops(in: [listing]).count == 1)
    }

    @Test("A評価物件の値下げは対象")
    func aGradeWithPriceDrop() {
        let listing = makeListing(
            assetGrade: "A",
            priceHistory: [("2026-06-01", 6000), ("2026-06-08", 5800)]
        )
        #expect(WatchlistFilter.priceDrops(in: [listing]).count == 1)
    }

    @Test("B評価・いいねなし物件の値下げは対象外")
    func bGradeNotLikedExcluded() {
        let listing = makeListing(
            assetGrade: "B",
            priceHistory: [("2026-06-01", 5000), ("2026-06-08", 4800)]
        )
        #expect(WatchlistFilter.priceDrops(in: [listing]).isEmpty)
    }

    @Test("値上げは対象外")
    func priceIncreaseExcluded() {
        let listing = makeListing(
            isLiked: true,
            priceHistory: [("2026-06-01", 5000), ("2026-06-08", 5200)]
        )
        #expect(listing.latestPriceChange == 200)
        #expect(WatchlistFilter.priceDrops(in: [listing]).isEmpty)
    }

    @Test("価格変動なし（履歴1件）は対象外")
    func noPriceHistoryExcluded() {
        let listing = makeListing(
            isLiked: true,
            priceHistory: [("2026-06-01", 5000)]
        )
        #expect(listing.latestPriceChange == nil)
        #expect(WatchlistFilter.priceDrops(in: [listing]).isEmpty)
    }

    @Test("いいね+S評価の両方に該当する物件もフィルタを通過する")
    func likedAndHighRatedPasses() {
        let listing = makeListing(
            isLiked: true,
            assetGrade: "S",
            priceHistory: [("2026-06-01", 7000), ("2026-06-08", 6500)]
        )
        #expect(WatchlistFilter.priceDrops(in: [listing]).count == 1)
    }

    @Test("混合リストから対象のみ抽出される")
    func mixedListFiltering() {
        let listings = [
            makeListing(isLiked: true, priceHistory: [("2026-06-01", 5000), ("2026-06-08", 4800)]),
            makeListing(assetGrade: "S", priceHistory: [("2026-06-01", 8000), ("2026-06-08", 7500)]),
            makeListing(assetGrade: "C", priceHistory: [("2026-06-01", 5000), ("2026-06-08", 4800)]),
            makeListing(isLiked: true, priceHistory: [("2026-06-01", 5000), ("2026-06-08", 5200)]),
            makeListing(isLiked: false, priceHistory: []),
        ]
        let result = WatchlistFilter.priceDrops(in: listings)
        #expect(result.count == 2)
    }

    @Test("値下げ幅の大きい順にソートされる")
    func sortedByDropMagnitude() {
        let small = makeListing(isLiked: true, priceHistory: [("2026-06-01", 5000), ("2026-06-08", 4900)])
        let large = makeListing(isLiked: true, priceHistory: [("2026-06-01", 8000), ("2026-06-08", 7000)])
        let result = WatchlistFilter.priceDrops(in: [small, large])
        #expect(result.first?.latestPriceChange == -1000)
        #expect(result.last?.latestPriceChange == -100)
    }

    @Test("limit 件数で打ち切られる")
    func limitApplied() {
        let listings = (1...8).map { i in
            makeListing(isLiked: true, priceHistory: [("2026-06-01", 5000), ("2026-06-08", 5000 - i * 10)])
        }
        #expect(WatchlistFilter.priceDrops(in: listings).count == 5)
        #expect(WatchlistFilter.priceDrops(in: listings, limit: 3).count == 3)
    }

    @Test("isWatchlisted の判定")
    func isWatchlistedJudgement() {
        #expect(WatchlistFilter.isWatchlisted(makeListing(isLiked: true)))
        #expect(WatchlistFilter.isWatchlisted(makeListing(assetGrade: "S")))
        #expect(WatchlistFilter.isWatchlisted(makeListing(assetGrade: "A")))
        #expect(!WatchlistFilter.isWatchlisted(makeListing(assetGrade: "B")))
        #expect(!WatchlistFilter.isWatchlisted(makeListing()))
    }
}
