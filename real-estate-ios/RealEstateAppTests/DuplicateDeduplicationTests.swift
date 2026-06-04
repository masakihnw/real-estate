import Testing
import Foundation
@testable import RealEstateApp

@Suite("重複排除: ダッシュボード新着デデュプ + 同期クリーンアップ")
@MainActor
struct DuplicateDeduplicationTests {

    // MARK: - Helpers

    private func makeListing(
        url: String = "https://suumo.jp/test/1",
        name: String = "テストマンション",
        supabaseIdentityKey: String? = nil,
        layout: String? = "3LDK",
        areaM2: Double? = 70.0,
        address: String? = "千代田区丸の内1",
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

    // MARK: - deduplicatedNewListings (prefStore なし)

    @Test("重複なし: 全物件がそのまま返る")
    func noDuplicatesReturnsAll() {
        let listings = [
            makeListing(url: "u1", name: "A", address: "千代田区1"),
            makeListing(url: "u2", name: "B", address: "中央区1"),
            makeListing(url: "u3", name: "C", address: "港区1"),
        ]
        let result = DashboardView.deduplicatedNewListings(listings)
        #expect(result.count == 3)
    }

    @Test("同一マンション別住戸: buildingGroupKey でデデュプされ1件になる")
    func sameBuildingDifferentUnitsDeduped() {
        let floor3 = makeListing(
            url: "u1", name: "テスト",
            supabaseIdentityKey: "テスト|3LDK|70|千代田区1|2020|3",
            floorPosition: 3,
            addedAt: Date().addingTimeInterval(-3600)
        )
        let floor5 = makeListing(
            url: "u2", name: "テスト",
            supabaseIdentityKey: "テスト|3LDK|70|千代田区1|2020|5",
            floorPosition: 5,
            addedAt: Date()
        )
        #expect(floor3.buildingGroupKey == floor5.buildingGroupKey)
        let result = DashboardView.deduplicatedNewListings([floor3, floor5])
        #expect(result.count == 1)
        #expect(result[0].url == "u2")
    }

    @Test("異なるマンション: 両方残る")
    func differentBuildingsKeptBoth() {
        let a = makeListing(url: "u1", name: "マンションA", address: "千代田区1")
        let b = makeListing(url: "u2", name: "マンションB", address: "千代田区2")
        let result = DashboardView.deduplicatedNewListings([a, b])
        #expect(result.count == 2)
    }

    @Test("空配列: パニックしない")
    func emptyArrayNoPanic() {
        let result = DashboardView.deduplicatedNewListings([])
        #expect(result.isEmpty)
    }

    @Test("addedAt 最新の物件が代表になる")
    func newestAddedAtIsRepresentative() {
        let older = makeListing(url: "u1", name: "テスト", addedAt: Date().addingTimeInterval(-3600))
        let newer = makeListing(url: "u2", name: "テスト", addedAt: Date())
        let result = DashboardView.deduplicatedNewListings([older, newer])
        #expect(result.count == 1)
        #expect(result[0].url == "u2")
    }

    // MARK: - deduplicatedNewListings (like/nope フィルタ)

    @Test("Like済み物件は除外される")
    func likedListingsExcluded() {
        let prefStore = BuildingPreferenceStore.shared
        let listing = makeListing(url: "u1", name: "テスト")
        let key = listing.identityKey
        prefStore.setLocalOnly(key, preference: .like)
        defer { prefStore.removeLocalOnly(key) }

        let result = DashboardView.deduplicatedNewListings([listing], prefStore: prefStore)
        #expect(result.isEmpty)
    }

    @Test("Nope済み物件は除外される")
    func nopedListingsExcluded() {
        let prefStore = BuildingPreferenceStore.shared
        let listing = makeListing(url: "u1", name: "テスト2", address: "港区1")
        let key = listing.identityKey
        prefStore.setLocalOnly(key, preference: .nope)
        defer { prefStore.removeLocalOnly(key) }

        let result = DashboardView.deduplicatedNewListings([listing], prefStore: prefStore)
        #expect(result.isEmpty)
    }

    @Test("未レビュー物件のみ残る")
    func onlyUnreviewedRemain() {
        let prefStore = BuildingPreferenceStore.shared
        let liked = makeListing(url: "u1", name: "A", address: "千代田区1")
        let unreviewed = makeListing(url: "u2", name: "B", address: "中央区1")

        prefStore.setLocalOnly(liked.identityKey, preference: .like)
        defer { prefStore.removeLocalOnly(liked.identityKey) }

        let result = DashboardView.deduplicatedNewListings([liked, unreviewed], prefStore: prefStore)
        #expect(result.count == 1)
        #expect(result[0].url == "u2")
    }

    @Test("prefStore nil ならフィルタなし（後方互換）")
    func nilPrefStoreNoFilter() {
        let listing = makeListing(url: "u1", name: "テスト")
        let result = DashboardView.deduplicatedNewListings([listing], prefStore: nil)
        #expect(result.count == 1)
    }

    @Test("同一マンション別住戸: 1件nopeすると全住戸が除外される")
    func nopingOneUnitExcludesAllUnitsOfSameBuilding() {
        let prefStore = BuildingPreferenceStore.shared
        let unitA = makeListing(url: "u1", name: "ブリリア有明", areaM2: 63.37, address: "江東区有明1", floorPosition: 16)
        let unitB = makeListing(url: "u2", name: "ブリリア有明", areaM2: 57.04, address: "江東区有明1", floorPosition: 30)
        let unitC = makeListing(url: "u3", name: "ブリリア有明", areaM2: 62.52, address: "江東区有明1", floorPosition: 2)
        let other = makeListing(url: "u4", name: "別のマンション", address: "中央区1")

        #expect(unitA.buildingGroupKey == unitB.buildingGroupKey)
        #expect(unitA.identityKey != unitB.identityKey)

        prefStore.setLocalOnly(unitA.identityKey, preference: .nope)
        defer { prefStore.removeLocalOnly(unitA.identityKey) }

        let result = DashboardView.deduplicatedNewListings(
            [unitA, unitB, unitC, other], prefStore: prefStore
        )
        #expect(result.count == 1)
        #expect(result[0].url == "u4")
    }

    @Test("同一マンション別住戸: 1件likeすると全住戸が除外される")
    func likingOneUnitExcludesAllUnitsOfSameBuilding() {
        let prefStore = BuildingPreferenceStore.shared
        let unitA = makeListing(url: "u1", name: "グランエスタ", areaM2: 81.59, address: "江東区新砂3")
        let unitB = makeListing(url: "u2", name: "グランエスタ", areaM2: 73.77, address: "江東区新砂3")

        prefStore.setLocalOnly(unitA.identityKey, preference: .like)
        defer { prefStore.removeLocalOnly(unitA.identityKey) }

        let result = DashboardView.deduplicatedNewListings(
            [unitA, unitB], prefStore: prefStore
        )
        #expect(result.isEmpty)
    }

    @Test("staleキー: レイアウト変更後もbuilding名で除外される")
    func staleKeyStillExcludesByBuildingName() {
        let prefStore = BuildingPreferenceStore.shared
        // nope時のidentityKey（レイアウトが2LDK+S）
        let staleKey = "ブリリア有明スカイタワー|2LDK+S（納戸）|63.37|江東区有明1|2010"
        prefStore.setLocalOnly(staleKey, preference: .nope)
        defer { prefStore.removeLocalOnly(staleKey) }

        // 現在のリスト（レイアウトが2LDKに変更されている）
        let unit = makeListing(url: "u1", name: "ブリリア有明スカイタワー", layout: "2LDK", areaM2: 63.37, address: "江東区有明1", builtYear: 2010)
        // identityKeyが変わっているので直接マッチしない
        #expect(unit.identityKey != staleKey)
        // だがbuilding名（最初の|まで）は一致する
        let result = DashboardView.deduplicatedNewListings([unit], prefStore: prefStore)
        #expect(result.isEmpty)
    }

    // MARK: - isBuildingReviewed

    @Test("isBuildingReviewed: like済みの建物はtrueを返す")
    func isBuildingReviewedForLikedBuilding() {
        let prefStore = BuildingPreferenceStore.shared
        let listing = makeListing(url: "u1", name: "テストマンション")
        prefStore.setLocalOnly(listing.identityKey, preference: .like)
        defer { prefStore.removeLocalOnly(listing.identityKey) }

        #expect(prefStore.isBuildingReviewed(listing) == true)
    }

    @Test("isBuildingReviewed: 同一建物の別住戸もtrueを返す")
    func isBuildingReviewedForSiblingUnit() {
        let prefStore = BuildingPreferenceStore.shared
        let unitA = makeListing(url: "u1", name: "テストタワー", areaM2: 70.0, address: "千代田区丸の内1")
        let unitB = makeListing(url: "u2", name: "テストタワー", areaM2: 55.0, address: "千代田区丸の内1")
        prefStore.setLocalOnly(unitA.identityKey, preference: .nope)
        defer { prefStore.removeLocalOnly(unitA.identityKey) }

        #expect(unitA.identityKey != unitB.identityKey)
        #expect(prefStore.isBuildingReviewed(unitB) == true)
    }

    @Test("isBuildingReviewed: 未レビューの建物はfalseを返す")
    func isBuildingReviewedForUnreviewedBuilding() {
        let listing = makeListing(url: "u1", name: "未レビュー物件", address: "港区1")
        #expect(BuildingPreferenceStore.shared.isBuildingReviewed(listing) == false)
    }

    // MARK: - SwipeSessionViewModel.pendingCount

    @Test("pendingCount: like/nope済み建物はカウントされない")
    func pendingCountExcludesReviewedBuildings() {
        let prefStore = BuildingPreferenceStore.shared
        let recentDate = Date()
        let reviewed = makeListing(url: "u1", name: "レビュー済み", address: "千代田区1", addedAt: recentDate)
        reviewed.propertyType = "chuko"
        let pending = makeListing(url: "u2", name: "未レビュー", address: "中央区1", addedAt: recentDate)
        pending.propertyType = "chuko"

        #expect(reviewed.isRecentlyAdded == true)
        #expect(pending.isRecentlyAdded == true)

        prefStore.setLocalOnly(reviewed.identityKey, preference: .nope)
        defer { prefStore.removeLocalOnly(reviewed.identityKey) }

        let count = SwipeSessionViewModel.pendingCount(from: [reviewed, pending])
        #expect(count == 1)
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
