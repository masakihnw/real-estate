import Testing
import Foundation
@testable import RealEstateApp

@Suite("SortCategory / SortOrder グループ化")
struct SortCategoryTests {

    typealias Sort = ListingSortOrder

    @Test("代表は8件で、すべて実在するソートケース")
    func representativesAreEight() {
        #expect(Sort.representatives.count == 8)
        // 重複なし
        #expect(Set(Sort.representatives).count == 8)
    }

    @Test("grouped は全ケースを漏れなく1回ずつ含む")
    func groupedCoversAllCasesOnce() {
        let flattened = Sort.grouped().flatMap { $0.sorts }
        #expect(flattened.count == Sort.allCases.count)
        #expect(Set(flattened) == Set(Sort.allCases))
    }

    @Test("grouped のカテゴリ順は 基本→立地→お金→資産性→AI")
    func groupedCategoryOrder() {
        let categories = Sort.grouped().map(\.category)
        #expect(categories == [.basic, .location, .money, .asset, .ai])
    }

    @Test("代表ソートのカテゴリが期待どおり")
    func representativeCategories() {
        #expect(Sort.addedDesc.category == .basic)
        #expect(Sort.walkAsc.category == .location)
        #expect(Sort.priceFairnessDesc.category == .asset)
        #expect(Sort.recommendationDesc.category == .ai)
        #expect(Sort.customMetricDesc.category == .asset)
    }

    @Test("only で絞ると該当カテゴリのみ・空カテゴリは消える")
    func groupedFilteredByAvailable() {
        let only: [Sort] = [.addedDesc, .priceAsc, .walkAsc]
        let grouped = Sort.grouped(only: only)
        // 基本（added, price）と 立地（walk）のみ
        #expect(grouped.map(\.category) == [.basic, .location])
        #expect(grouped.flatMap { $0.sorts }.count == 3)
    }

    @Test("only が空なら grouped も空")
    func groupedEmptyWhenNoneAvailable() {
        #expect(Sort.grouped(only: []).isEmpty)
    }

    @Test("全カテゴリに最低1ケースが割り当たっている")
    func everyCategoryHasMembers() {
        for category in SortCategory.allCases {
            #expect(Sort.allCases.contains { $0.category == category })
        }
    }
}
