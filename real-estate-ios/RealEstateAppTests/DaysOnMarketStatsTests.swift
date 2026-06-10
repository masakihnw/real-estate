import Testing
import Foundation
@testable import RealEstateApp

@Suite("DaysOnMarketStats")
struct DaysOnMarketStatsTests {

    private func isoDaysAgo(_ days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return Listing.isoDayFormatter.string(from: date)
    }

    private func makeListing(
        address: String = "東京都江東区豊洲1-1",
        layout: String? = "3LDK",
        daysOnMarket: Int? = nil,
        url: String? = nil
    ) -> Listing {
        Listing(
            source: "test",
            url: url ?? "https://example.com/\(UUID().uuidString)",
            name: "テスト物件",
            address: address,
            layout: layout,
            firstSeenAt: daysOnMarket.map { isoDaysAgo($0) }
        )
    }

    @Test("同区・同間取りの平均掲載日数")
    func averageOfSameSegment() {
        let target = makeListing(daysOnMarket: 50, url: "https://example.com/target")
        let others = [
            makeListing(daysOnMarket: 10),
            makeListing(daysOnMarket: 20),
            makeListing(daysOnMarket: 30),
        ]
        let avg = DaysOnMarketStats.averageDays(
            ward: target.wardName, layout: "3LDK",
            excludingURL: target.url, in: others + [target]
        )
        #expect(avg == 20)
    }

    @Test("対象物件自身は平均から除外される")
    func targetExcluded() {
        let target = makeListing(daysOnMarket: 100, url: "https://example.com/target")
        let others = [
            makeListing(daysOnMarket: 10),
            makeListing(daysOnMarket: 10),
            makeListing(daysOnMarket: 10),
        ]
        let avg = DaysOnMarketStats.averageDays(
            ward: target.wardName, layout: "3LDK",
            excludingURL: target.url, in: others + [target]
        )
        #expect(avg == 10)
    }

    @Test("サンプル不足なら nil")
    func insufficientSamples() {
        let target = makeListing(url: "https://example.com/target")
        let others = [makeListing(daysOnMarket: 10), makeListing(daysOnMarket: 20)]
        #expect(DaysOnMarketStats.averageDays(
            ward: target.wardName, layout: "3LDK",
            excludingURL: target.url, in: others
        ) == nil)
    }

    @Test("別の区・別間取りは平均に含めない")
    func differentSegmentExcluded() {
        let target = makeListing(url: "https://example.com/target")
        let others = [
            makeListing(address: "東京都港区芝1-1", daysOnMarket: 99),
            makeListing(layout: "2LDK", daysOnMarket: 99),
            makeListing(daysOnMarket: 10),
            makeListing(daysOnMarket: 20),
            makeListing(daysOnMarket: 30),
        ]
        let avg = DaysOnMarketStats.averageDays(
            ward: target.wardName, layout: "3LDK",
            excludingURL: target.url, in: others
        )
        #expect(avg == 20)
    }

    @Test("比較ラベルの文言")
    func comparisonLabels() {
        #expect(DaysOnMarketStats.comparisonLabel(listingDays: 60, averageDays: 30)
            .contains("30日長い"))
        #expect(DaysOnMarketStats.comparisonLabel(listingDays: 10, averageDays: 30)
            .contains("20日短い"))
        #expect(DaysOnMarketStats.comparisonLabel(listingDays: 31, averageDays: 30)
            .contains("並み"))
    }
}
