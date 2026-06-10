import Testing
import Foundation
@testable import RealEstateApp

@Suite("TimelineFeed")
struct TimelineFeedTests {

    private let now = Date()

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    private func isoDay(_ date: Date) -> String {
        Listing.isoDayFormatter.string(from: date)
    }

    private func makeListing(
        addedAt: Date,
        isRelisted: Bool = false,
        priceHistory: [(Date, Int)] = []
    ) -> Listing {
        let json: String? = priceHistory.isEmpty ? nil : {
            let entries = priceHistory.map { "{\"date\":\"\(isoDay($0.0))\",\"price_man\":\($0.1)}" }
            return "[\(entries.joined(separator: ","))]"
        }()
        let listing = Listing(
            source: "test",
            url: "https://example.com/\(UUID().uuidString)",
            name: "テスト物件",
            isRelisted: isRelisted,
            priceHistoryJSON: json
        )
        listing.addedAt = addedAt
        return listing
    }

    @Test("期間内の新着が added として載る")
    func recentAddition() {
        let listing = makeListing(addedAt: daysAgo(2))
        let items = TimelineFeed.build(from: [listing], days: 7, now: now)
        #expect(items.count == 1)
        #expect(items[0].kind == .added)
    }

    @Test("再掲フラグ付きは relisted として載る")
    func relisted() {
        let listing = makeListing(addedAt: daysAgo(1), isRelisted: true)
        let items = TimelineFeed.build(from: [listing], days: 7, now: now)
        #expect(items[0].kind == .relisted)
    }

    @Test("期間外の新着は載らない")
    func oldAdditionExcluded() {
        let listing = makeListing(addedAt: daysAgo(30))
        #expect(TimelineFeed.build(from: [listing], days: 7, now: now).isEmpty)
    }

    @Test("期間内の値下げが priceDrop として載る")
    func priceDrop() {
        let listing = makeListing(
            addedAt: daysAgo(60),
            priceHistory: [(daysAgo(40), 9800), (daysAgo(3), 9500)]
        )
        let items = TimelineFeed.build(from: [listing], days: 7, now: now)
        #expect(items.count == 1)
        #expect(items[0].kind == .priceDrop(amount: 300))
    }

    @Test("値上げは priceRaise として載る")
    func priceRaise() {
        let listing = makeListing(
            addedAt: daysAgo(60),
            priceHistory: [(daysAgo(40), 9500), (daysAgo(2), 9800)]
        )
        let items = TimelineFeed.build(from: [listing], days: 7, now: now)
        #expect(items[0].kind == .priceRaise(amount: 300))
    }

    @Test("日付降順でソートされ limit で打ち切られる")
    func sortedAndLimited() {
        let listings = (1...10).map { makeListing(addedAt: daysAgo($0 % 5)) }
        let items = TimelineFeed.build(from: listings, days: 7, limit: 4, now: now)
        #expect(items.count == 4)
        let dates = items.map(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("新着と値下げの両方があれば2イベント載る")
    func bothEvents() {
        let listing = makeListing(
            addedAt: daysAgo(5),
            priceHistory: [(daysAgo(5), 9800), (daysAgo(1), 9500)]
        )
        let items = TimelineFeed.build(from: [listing], days: 7, now: now)
        #expect(items.count == 2)
    }
}
