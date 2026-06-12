import Testing
import Foundation
@testable import RealEstateApp

@Suite("NopedFilter")
struct NopedFilterTests {

    private func makeListing(url: String, name: String) -> Listing {
        Listing(url: url, name: name, propertyType: "chuko")
    }

    @Test("nopedKeys に一致する物件だけを返す")
    func filtersByNopedKeys() {
        let a = makeListing(url: "https://example.com/a", name: "物件A")
        let b = makeListing(url: "https://example.com/b", name: "物件B")
        let c = makeListing(url: "https://example.com/c", name: "物件C")
        let noped: Set<String> = [a.identityKey, c.identityKey]

        let result = NopedFilter.filter(listings: [a, b, c], nopedKeys: noped)

        #expect(result.count == 2)
        #expect(result.map(\.url) == [a.url, c.url], "入力順が保持されていない")
    }

    @Test("nopedKeys が空なら空配列（全件返さない）")
    func emptyKeysReturnsEmpty() {
        let a = makeListing(url: "https://example.com/a", name: "物件A")
        let result = NopedFilter.filter(listings: [a], nopedKeys: [])
        #expect(result.isEmpty)
    }

    @Test("listings が空なら空配列")
    func emptyListingsReturnsEmpty() {
        let result = NopedFilter.filter(listings: [], nopedKeys: ["key|x"])
        #expect(result.isEmpty)
    }

    @Test("一致なしなら空配列")
    func noMatchReturnsEmpty() {
        let a = makeListing(url: "https://example.com/a", name: "物件A")
        let result = NopedFilter.filter(listings: [a], nopedKeys: ["存在しない|key"])
        #expect(result.isEmpty)
    }
}
