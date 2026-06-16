import Testing
import Foundation
@testable import RealEstateApp

@Suite("Listing.preferenceKey")
struct PreferenceKeyTests {

    private func makeListing(
        name: String = "テストマンション",
        layout: String? = "3LDK",
        areaM2: Double? = 62.0,
        address: String? = "台東区元浅草",
        builtYear: Int? = 2003,
        supabaseIdentityKey: String? = nil
    ) -> Listing {
        let listing = Listing(
            source: "test",
            url: "https://example.com/\(UUID().uuidString)",
            name: name,
            address: address,
            areaM2: areaM2,
            layout: layout,
            builtYear: builtYear
        )
        listing.supabaseIdentityKey = supabaseIdentityKey
        return listing
    }

    @Test("supabaseIdentityKey があればそれを返す")
    func prefersSupabaseKey() {
        let listing = makeListing(supabaseIdentityKey: "ルピナス台東レジデンス|3LDK|62.0|台東区元浅草|2003|3")
        #expect(listing.preferenceKey == "ルピナス台東レジデンス|3LDK|62.0|台東区元浅草|2003|3")
    }

    @Test("supabaseIdentityKey が nil なら端末計算 identityKey にフォールバック")
    func fallsBackWhenNil() {
        let listing = makeListing(supabaseIdentityKey: nil)
        #expect(listing.preferenceKey == listing.identityKey)
    }

    @Test("supabaseIdentityKey が空文字なら identityKey にフォールバック")
    func fallsBackWhenEmpty() {
        let listing = makeListing(supabaseIdentityKey: "")
        #expect(listing.preferenceKey == listing.identityKey)
    }

    @Test("販促文言で物件名が揺れても supabaseIdentityKey は安定（再表示バグの核心）")
    func stableAcrossNameNoise() {
        // 同一物件だが name に販促文言が混ざったケース
        let clean = makeListing(
            name: "ルピナス台東レジデンス",
            supabaseIdentityKey: "ルピナス台東レジデンス|3LDK|62.0|台東区元浅草|2003|3"
        )
        let noisy = makeListing(
            name: "ルピナス台東レジデンス 秋葉原利用可/新御徒町まで6分/ペット 3階",
            supabaseIdentityKey: "ルピナス台東レジデンス|3LDK|62.0|台東区元浅草|2003|3"
        )
        // 端末計算キーは名前の揺れでズレるが、preferenceKey は一致する
        #expect(clean.identityKey != noisy.identityKey)
        #expect(clean.preferenceKey == noisy.preferenceKey)
    }
}

@Suite("BuildingPreferenceStore.isBuildingReviewed (preferenceKey)")
@MainActor
struct IsBuildingReviewedPreferenceKeyTests {

    private func makeListing(supabaseIdentityKey: String?) -> Listing {
        let listing = Listing(
            source: "test",
            url: "https://example.com/\(UUID().uuidString)",
            name: "建物X",
            address: "中央区晴海",
            areaM2: 70,
            layout: "3LDK",
            builtYear: 2010
        )
        listing.supabaseIdentityKey = supabaseIdentityKey
        return listing
    }

    @Test("サーバーキーの建物名で既読判定される（別住戸でも建物単位で除外）")
    func reviewedByServerBuildingName() {
        let store = BuildingPreferenceStore.shared
        store.removeLocalOnly("ザ晴海レジデンス|2LDK|75.95|中央区晴海5|2009|3")
        // 5階・別間取りの住戸を like 済みとして登録
        store.setLocalOnly("ザ晴海レジデンス|2LDK|75.95|中央区晴海5|2009|3", preference: .like)

        // 別住戸（3LDK・別階）でも同じ建物名なら既読
        let other = makeListing(supabaseIdentityKey: "ザ晴海レジデンス|3LDK|80.0|中央区晴海5|2009|10")
        #expect(store.isBuildingReviewed(other))

        // 後片付け
        store.removeLocalOnly("ザ晴海レジデンス|2LDK|75.95|中央区晴海5|2009|3")
    }
}
