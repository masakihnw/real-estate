import Testing
import Foundation
@testable import RealEstateApp

@Suite("FilterMatchCounter 保存フィルタの新着マッチ")
struct FilterMatchCounterTests {

    private func makeListing(
        url: String,
        name: String,
        priceMan: Int?,
        addedDaysAgo: Double = 1,
        isDelisted: Bool = false
    ) -> Listing {
        let l = Listing(url: url, name: name, propertyType: "chuko", priceMan: priceMan)
        l.addedAt = Date().addingTimeInterval(-addedDaysAgo * 24 * 3600)
        l.isDelisted = isDelisted
        return l
    }

    private func template(name: String, priceMax: Int?) -> FilterTemplate {
        var filter = ListingFilter()
        filter.priceMax = priceMax
        return FilterTemplate(name: name, filter: filter)
    }

    // MARK: - newListings

    @Test("新着 = 2日以内追加かつ掲載中")
    func newListingsDefinition() {
        let fresh = makeListing(url: "https://x/1", name: "新着", priceMan: 9_000, addedDaysAgo: 1)
        let old = makeListing(url: "https://x/2", name: "古い", priceMan: 9_000, addedDaysAgo: 10)
        let delisted = makeListing(url: "https://x/3", name: "終了", priceMan: 9_000, addedDaysAgo: 1, isDelisted: true)
        let result = FilterMatchCounter.newListings(in: [fresh, old, delisted])
        #expect(result.map(\.url) == [fresh.url])
    }

    // MARK: - matchCounts

    @Test("条件にマッチする新着の件数をテンプレートIDごとに返す")
    func countsMatches() {
        let cheap = makeListing(url: "https://x/1", name: "A", priceMan: 8_000)
        let pricey = makeListing(url: "https://x/2", name: "B", priceMan: 15_000)
        let budget = template(name: "予算内", priceMax: 10_000)
        let all = template(name: "すべて", priceMax: nil)

        let counts = FilterMatchCounter.matchCounts(
            newListings: [cheap, pricey], templates: [budget, all]
        )
        #expect(counts[budget.id] == 1)
        #expect(counts[all.id] == 2)
    }

    @Test("マッチ0件のテンプレートは結果に含まれない")
    func excludesZeroMatch() {
        let pricey = makeListing(url: "https://x/1", name: "A", priceMan: 15_000)
        let budget = template(name: "予算内", priceMax: 10_000)
        let counts = FilterMatchCounter.matchCounts(newListings: [pricey], templates: [budget])
        #expect(counts.isEmpty)
    }

    @Test("新着が空なら空辞書（apply を呼ばない早期 return）")
    func emptyNewListings() {
        let budget = template(name: "予算内", priceMax: 10_000)
        let counts = FilterMatchCounter.matchCounts(newListings: [], templates: [budget])
        #expect(counts.isEmpty)
    }

    @Test("テンプレートが空なら空辞書")
    func emptyTemplates() {
        let l = makeListing(url: "https://x/1", name: "A", priceMan: 8_000)
        let counts = FilterMatchCounter.matchCounts(newListings: [l], templates: [])
        #expect(counts.isEmpty)
    }

    // MARK: - matchSummaries

    @Test("通知用サマリーはマッチ数降順・0件除外")
    func summariesSortedByCount() {
        let l1 = makeListing(url: "https://x/1", name: "A", priceMan: 8_000)
        let l2 = makeListing(url: "https://x/2", name: "B", priceMan: 9_000)
        let l3 = makeListing(url: "https://x/3", name: "C", priceMan: 15_000)
        let narrow = template(name: "8千万以下", priceMax: 8_000)   // 1件
        let wide = template(name: "1億以下", priceMax: 10_000)      // 2件
        let none = template(name: "5千万以下", priceMax: 5_000)     // 0件

        let summaries = FilterMatchCounter.matchSummaries(
            newListings: [l1, l2, l3], templates: [narrow, wide, none]
        )
        #expect(summaries.count == 2)
        #expect(summaries[0].name == "1億以下")
        #expect(summaries[0].count == 2)
        #expect(summaries[1].name == "8千万以下")
        #expect(summaries[1].count == 1)
    }
}
