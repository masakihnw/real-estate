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

    @Test("supabaseIdentityKey で保存された nopedKey は preferenceKey で照合される")
    func filtersBySupabaseKey() {
        let a = makeListing(url: "https://example.com/a", name: "物件A")
        a.supabaseIdentityKey = "物件A|3LDK|62.0|台東区|2003|3"
        // サーバーキーで保存されたケース。端末計算 identityKey ではヒットしない。
        let noped: Set<String> = ["物件A|3LDK|62.0|台東区|2003|3"]

        let result = NopedFilter.filter(listings: [a], nopedKeys: noped)

        #expect(result.map(\.url) == [a.url])
        #expect(!noped.contains(a.identityKey), "前提: 旧 identityKey とは一致しない")
    }
}
