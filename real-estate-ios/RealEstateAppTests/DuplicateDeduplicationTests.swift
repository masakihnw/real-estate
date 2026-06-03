import Testing
import Foundation
@testable import RealEstateApp

@Suite("重複排除: ダッシュボード新着デデュプ + 同期クリーンアップ")
struct DuplicateDeduplicationTests {

    // MARK: - Helpers

    private func makeListing(
        url: String = "https://suumo.jp/test/1",
        name: String = "テストマンション",
        supabaseIdentityKey: String? = nil,
        layout: String? = "3LDK",
        areaM2: Double? = 70.0,
        address: String? = "千代田区1",
        builtYear: Int? = 2020,
        floorPosition: Int? = nil,
        addedAt: Date = Date(),
        isLiked: Bool = false,
        memo: String? = nil,
        fetchedAt: Date = Date()
    ) -> Listing {
        let l = Listing(
            url: url,
            name: name,
            address: address,
            areaM2: areaM2,
            layout: layout,
            builtYear: builtYear,
            floorPosition: floorPosition,
            fetchedAt: fetchedAt,
            addedAt: addedAt,
            isLiked: isLiked
        )
        l.supabaseIdentityKey = supabaseIdentityKey
        l.memo = memo
        return l
    }

    // MARK: - deduplicatedNewListings

    @Test("重複なし: 全物件がそのまま返る")
    func noDuplicatesReturnsAll() {
        let listings = [
            makeListing(url: "u1", name: "A", supabaseIdentityKey: "a|3LDK|70|addr|2020|3"),
            makeListing(url: "u2", name: "B", supabaseIdentityKey: "b|3LDK|65|addr|2019|5"),
            makeListing(url: "u3", name: "C", supabaseIdentityKey: "c|2LDK|55|addr|2018|2"),
        ]
        let result = DashboardView.deduplicatedNewListings(listings)
        #expect(result.count == 3)
    }

    @Test("supabaseIdentityKey 重複: 先に追加された方（addedAt が新しい方）のみ残る")
    func dbKeyDuplicatesKeptByNewest() {
        let older = makeListing(
            url: "u1", name: "A",
            supabaseIdentityKey: "same|3LDK|70|addr|2020|3",
            addedAt: Date().addingTimeInterval(-3600)
        )
        let newer = makeListing(
            url: "u2", name: "A",
            supabaseIdentityKey: "same|3LDK|70|addr|2020|3",
            addedAt: Date()
        )
        let result = DashboardView.deduplicatedNewListings([older, newer])
        #expect(result.count == 1)
        #expect(result[0].url == "u2")
    }

    @Test("supabaseIdentityKey nil: Swift identityKey でデデュプ")
    func fallsBackToSwiftKey() {
        let a = makeListing(url: "u1", name: "テスト", supabaseIdentityKey: nil, addedAt: Date())
        let b = makeListing(url: "u2", name: "テスト", supabaseIdentityKey: nil, addedAt: Date().addingTimeInterval(-1))
        #expect(a.identityKey == b.identityKey)
        let result = DashboardView.deduplicatedNewListings([a, b])
        #expect(result.count == 1)
    }

    @Test("異なる floor_position の物件: supabaseIdentityKey が異なればどちらも残る")
    func differentFloorsDifferentDbKeys() {
        let floor3 = makeListing(
            url: "u1", name: "テスト",
            supabaseIdentityKey: "テスト|3LDK|70|addr|2020|3",
            floorPosition: 3
        )
        let floor5 = makeListing(
            url: "u2", name: "テスト",
            supabaseIdentityKey: "テスト|3LDK|70|addr|2020|5",
            floorPosition: 5
        )
        let result = DashboardView.deduplicatedNewListings([floor3, floor5])
        #expect(result.count == 2)
    }

    // MARK: - pickKeepAndRemove

    @Test("ユーザーデータありの方を保持")
    func keepsListingWithUserData() {
        let withLike = makeListing(url: "u1", name: "A", isLiked: true, fetchedAt: Date().addingTimeInterval(-3600))
        let noData = makeListing(url: "u2", name: "A", isLiked: false, fetchedAt: Date())
        let (keep, remove) = SupabaseListingStore.pickKeepAndRemove(withLike, noData)
        #expect(keep.url == "u1")
        #expect(remove.url == "u2")
    }

    @Test("ユーザーデータありの方を保持（逆順）")
    func keepsListingWithUserDataReverse() {
        let noData = makeListing(url: "u1", name: "A", isLiked: false, fetchedAt: Date())
        let withMemo = makeListing(url: "u2", name: "A", memo: "メモあり", fetchedAt: Date().addingTimeInterval(-3600))
        let (keep, remove) = SupabaseListingStore.pickKeepAndRemove(noData, withMemo)
        #expect(keep.url == "u2")
        #expect(remove.url == "u1")
    }

    @Test("両方ユーザーデータなし: 新しい方を保持")
    func keepsNewerWhenNoUserData() {
        let older = makeListing(url: "u1", name: "A", fetchedAt: Date().addingTimeInterval(-3600))
        let newer = makeListing(url: "u2", name: "A", fetchedAt: Date())
        let (keep, remove) = SupabaseListingStore.pickKeepAndRemove(older, newer)
        #expect(keep.url == "u2")
        #expect(remove.url == "u1")
    }

    @Test("両方ユーザーデータあり: 新しい方を保持")
    func keepsBothHaveDataNewerWins() {
        let older = makeListing(url: "u1", name: "A", isLiked: true, fetchedAt: Date().addingTimeInterval(-3600))
        let newer = makeListing(url: "u2", name: "A", isLiked: true, fetchedAt: Date())
        let (keep, remove) = SupabaseListingStore.pickKeepAndRemove(older, newer)
        #expect(keep.url == "u2")
        #expect(remove.url == "u1")
    }
}
