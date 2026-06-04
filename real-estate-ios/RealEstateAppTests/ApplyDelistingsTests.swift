import Testing
import Foundation
import SwiftData
@testable import RealEstateApp

@Suite("applyDelistings")
struct ApplyDelistingsTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Listing.self, TransactionRecord.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeListing(
        url: String = "https://example.com/1",
        name: String = "テスト物件",
        dbKey: String = "test-building|chuko",
        isLiked: Bool = false,
        isDelisted: Bool = false,
        memo: String? = nil,
        propertyType: String = "chuko"
    ) -> Listing {
        let l = Listing(url: url, name: name, propertyType: propertyType)
        l.supabaseIdentityKey = dbKey
        l.isLiked = isLiked
        l.isDelisted = isDelisted
        l.memo = memo
        return l
    }

    @Test("ユーザーデータなしの物件は削除される")
    func deletesListingWithoutUserData() throws {
        let ctx = try makeContext()
        let listing = makeListing(dbKey: "building-A|chuko")
        ctx.insert(listing)
        try ctx.save()

        SupabaseListingStore.shared.applyDelistings(
            keys: ["building-A|chuko"],
            propertyType: "chuko",
            modelContext: ctx
        )

        let remaining = try ctx.fetch(FetchDescriptor<Listing>())
        #expect(remaining.isEmpty)
    }

    @Test("isLiked な物件は isDelisted=true になり削除されない")
    func marksLikedListingAsDelisted() throws {
        let ctx = try makeContext()
        let listing = makeListing(dbKey: "building-B|chuko", isLiked: true)
        ctx.insert(listing)
        try ctx.save()

        SupabaseListingStore.shared.applyDelistings(
            keys: ["building-B|chuko"],
            propertyType: "chuko",
            modelContext: ctx
        )

        let remaining = try ctx.fetch(FetchDescriptor<Listing>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.isDelisted == true)
    }

    @Test("メモ付き物件は isDelisted=true になり削除されない")
    func marksListingWithMemoAsDelisted() throws {
        let ctx = try makeContext()
        let listing = makeListing(dbKey: "building-C|chuko", memo: "気になる")
        ctx.insert(listing)
        try ctx.save()

        SupabaseListingStore.shared.applyDelistings(
            keys: ["building-C|chuko"],
            propertyType: "chuko",
            modelContext: ctx
        )

        let remaining = try ctx.fetch(FetchDescriptor<Listing>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.isDelisted == true)
    }

    @Test("delist対象外の物件は影響を受けない")
    func leavesNonMatchingListingsAlone() throws {
        let ctx = try makeContext()
        let listing = makeListing(dbKey: "building-D|chuko")
        ctx.insert(listing)
        try ctx.save()

        SupabaseListingStore.shared.applyDelistings(
            keys: ["building-OTHER|chuko"],
            propertyType: "chuko",
            modelContext: ctx
        )

        let remaining = try ctx.fetch(FetchDescriptor<Listing>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.isDelisted == false)
    }

    @Test("既に isDelisted=true の物件は再処理されない")
    func skipsAlreadyDelistedListings() throws {
        let ctx = try makeContext()
        let listing = makeListing(dbKey: "building-E|chuko", isLiked: true, isDelisted: true)
        ctx.insert(listing)
        try ctx.save()

        SupabaseListingStore.shared.applyDelistings(
            keys: ["building-E|chuko"],
            propertyType: "chuko",
            modelContext: ctx
        )

        let remaining = try ctx.fetch(FetchDescriptor<Listing>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.isDelisted == true)
    }

    @Test("空のキーリストは何もしない")
    func emptyKeysIsNoOp() throws {
        let ctx = try makeContext()
        let listing = makeListing(dbKey: "building-F|chuko")
        ctx.insert(listing)
        try ctx.save()

        SupabaseListingStore.shared.applyDelistings(
            keys: [],
            propertyType: "chuko",
            modelContext: ctx
        )

        let remaining = try ctx.fetch(FetchDescriptor<Listing>())
        #expect(remaining.count == 1)
    }

    @Test("複数物件の混在: liked は保持、データなしは削除")
    func mixedListings() throws {
        let ctx = try makeContext()
        let liked = makeListing(url: "https://example.com/liked", dbKey: "bld-liked|chuko", isLiked: true)
        let plain = makeListing(url: "https://example.com/plain", dbKey: "bld-plain|chuko")
        let unrelated = makeListing(url: "https://example.com/other", dbKey: "bld-safe|chuko")
        ctx.insert(liked)
        ctx.insert(plain)
        ctx.insert(unrelated)
        try ctx.save()

        SupabaseListingStore.shared.applyDelistings(
            keys: ["bld-liked|chuko", "bld-plain|chuko"],
            propertyType: "chuko",
            modelContext: ctx
        )

        let remaining = try ctx.fetch(FetchDescriptor<Listing>())
        #expect(remaining.count == 2)
        let likedResult = remaining.first { $0.url == "https://example.com/liked" }
        #expect(likedResult?.isDelisted == true)
        let unrelatedResult = remaining.first { $0.url == "https://example.com/other" }
        #expect(unrelatedResult?.isDelisted == false)
    }

    @Test("supabaseIdentityKey が nil の物件はスキップされる")
    func skipsListingWithNilIdentityKey() throws {
        let ctx = try makeContext()
        let listing = Listing(url: "https://example.com/old", name: "旧物件", propertyType: "chuko")
        listing.supabaseIdentityKey = nil
        ctx.insert(listing)
        try ctx.save()

        SupabaseListingStore.shared.applyDelistings(
            keys: ["any-key|chuko"],
            propertyType: "chuko",
            modelContext: ctx
        )

        let remaining = try ctx.fetch(FetchDescriptor<Listing>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.isDelisted == false)
    }
}
