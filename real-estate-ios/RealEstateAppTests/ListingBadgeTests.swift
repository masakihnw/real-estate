import Testing
import Foundation
@testable import RealEstateApp

@Suite("Listing Badge & Recently Added")
struct ListingBadgeTests {

    // MARK: - isRecentlyAdded

    @Test("addedAt が今日 → isRecentlyAdded = true")
    func addedTodayIsRecent() {
        let listing = Listing(source: "test", url: "https://example.com/1", name: "テスト物件", addedAt: Date())
        #expect(listing.isRecentlyAdded)
    }

    @Test("addedAt が1日前 → isRecentlyAdded = true")
    func addedYesterdayIsRecent() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let listing = Listing(source: "test", url: "https://example.com/2", name: "テスト物件", addedAt: yesterday)
        #expect(listing.isRecentlyAdded)
    }

    @Test("addedAt が3日前 → isRecentlyAdded = false")
    func addedThreeDaysAgoIsNotRecent() {
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let listing = Listing(source: "test", url: "https://example.com/3", name: "テスト物件", addedAt: threeDaysAgo)
        #expect(!listing.isRecentlyAdded)
    }

    @Test("addedAt が1週間前 → isRecentlyAdded = false")
    func addedOneWeekAgoIsNotRecent() {
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let listing = Listing(source: "test", url: "https://example.com/4", name: "テスト物件", addedAt: oneWeekAgo)
        #expect(!listing.isRecentlyAdded)
    }

    // MARK: - isAddedToday (既存、regression)

    @Test("addedAt が今日 → isAddedToday = true")
    func addedTodayIsToday() {
        let listing = Listing(source: "test", url: "https://example.com/5", name: "テスト物件", addedAt: Date())
        #expect(listing.isAddedToday)
    }

    @Test("addedAt が昨日 → isAddedToday = false")
    func addedYesterdayIsNotToday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let listing = Listing(source: "test", url: "https://example.com/6", name: "テスト物件", addedAt: yesterday)
        #expect(!listing.isAddedToday)
    }

    // MARK: - Badge type determination

    @Test("新規マンション → New バッジ")
    func newBuildingShowsNewBadge() {
        let listing = Listing(source: "test", url: "https://example.com/7", name: "テスト物件",
                              addedAt: Date(), isNew: true, isNewBuilding: true)
        let isNewBadge = listing.isNewBuilding || listing.isRelisted
        #expect(isNewBadge)
    }

    @Test("再掲載物件 → New バッジ")
    func relistedShowsNewBadge() {
        let listing = Listing(source: "test", url: "https://example.com/8", name: "テスト物件",
                              addedAt: Date(), isRelisted: true)
        let isNewBadge = listing.isNewBuilding || listing.isRelisted
        #expect(isNewBadge)
    }

    @Test("既存マンション別部屋 → 別部屋バッジ")
    func existingBuildingNewUnitShowsBetsuHeyaBadge() {
        let listing = Listing(source: "test", url: "https://example.com/9", name: "テスト物件",
                              addedAt: Date(), isNew: true, isNewBuilding: false, isRelisted: false)
        let isNewBadge = listing.isNewBuilding || listing.isRelisted
        #expect(!isNewBadge)
    }

    @Test("isRelisted のデフォルトは false")
    func isRelistedDefaultIsFalse() {
        let listing = Listing(source: "test", url: "https://example.com/10", name: "テスト物件")
        #expect(!listing.isRelisted)
    }

    // MARK: - Badge visibility (2-day window + type)

    @Test("今日追加の再掲載物件はバッジ表示対象")
    func recentRelistedShowsBadge() {
        let listing = Listing(source: "test", url: "https://example.com/11", name: "テスト物件",
                              addedAt: Date(), isRelisted: true)
        #expect(listing.isRecentlyAdded)
        #expect(listing.isNewBuilding || listing.isRelisted)
    }

    @Test("3日前の再掲載物件はバッジ非表示")
    func oldRelistedNoBadge() {
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let listing = Listing(source: "test", url: "https://example.com/12", name: "テスト物件",
                              addedAt: threeDaysAgo, isRelisted: true)
        #expect(!listing.isRecentlyAdded)
    }
}
