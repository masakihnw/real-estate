import Testing
import Foundation
@testable import RealEstateApp

/// like/nope のローカルキャッシュ（起動直後の既読を同期復元してチラつきを防ぐ）の検証。
@Suite("BuildingPreference local cache")
@MainActor
struct BuildingPreferenceCacheTests {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "test.buildingpref.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("保存後に新しいインスタンス（=コールドスタート）で既読が同期復元される")
    func persistsAndReloadsOnColdStart() {
        let defaults = isolatedDefaults()
        let store1 = BuildingPreferenceStore(defaults: defaults)
        store1.setLocalOnly("ザ晴海レジデンス|2LDK|75.95|中央区晴海5|2009|3", preference: .nope)
        store1.setLocalOnly("ブリリア|3LDK|72|豊島区高田1|2022|5", preference: .like)
        store1.saveLocalForTesting()

        // 別インスタンス＝アプリ再起動相当。init で defaults から同期ロードされる。
        let store2 = BuildingPreferenceStore(defaults: defaults)
        #expect(store2.isNoped("ザ晴海レジデンス|2LDK|75.95|中央区晴海5|2009|3"))
        #expect(store2.isLiked("ブリリア|3LDK|72|豊島区高田1|2022|5"))
    }

    @Test("起動直後（fetch前）でも既読建物が isBuildingReviewed で除外される")
    func reviewedAvailableBeforeFetch() {
        let defaults = isolatedDefaults()
        let seed = BuildingPreferenceStore(defaults: defaults)
        seed.setLocalOnly("テスト建物|2LDK|60|中央区晴海5|2009|3", preference: .nope)
        seed.saveLocalForTesting()

        // コールドスタート相当のインスタンス（fetch していない）
        let coldStart = BuildingPreferenceStore(defaults: defaults)
        let listing = Listing(
            source: "test",
            url: "https://example.com/\(UUID().uuidString)",
            name: "テスト建物",
            address: "中央区晴海5",
            areaM2: 80,
            layout: "3LDK",
            builtYear: 2009
        )
        listing.supabaseIdentityKey = "テスト建物|3LDK|80|中央区晴海5|2009|10"
        #expect(coldStart.isBuildingReviewed(listing), "fetch 前でもローカルキャッシュで建物単位の既読が効く")
    }

    @Test("空キャッシュなら既読なし")
    func emptyCacheNoReviewed() {
        let store = BuildingPreferenceStore(defaults: isolatedDefaults())
        #expect(store.nopedKeys.isEmpty)
        #expect(store.likedKeys.isEmpty)
    }
}
