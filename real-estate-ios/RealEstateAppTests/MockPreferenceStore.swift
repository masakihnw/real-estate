import Foundation
@testable import RealEstateApp

/// テスト用の like/nope 設定ストア。ネットワーク（Supabase）に書き込まず、
/// メモリ上で建物名単位の既読判定を再現する。
///
/// 本番の `BuildingPreferenceStore.shared` をテストの `commitSwipe` から呼ぶと
/// 実 Supabase に書き込んでしまう（過去に `card0_<hash>` 廃キーが本番に混入した原因）。
/// これを防ぐため `SwipeSessionViewModel` にこのモックを注入する。
@MainActor
final class MockPreferenceStore: SwipePreferenceStoring {
    private(set) var liked = Set<String>()
    private(set) var noped = Set<String>()

    func isBuildingReviewed(_ listing: Listing) -> Bool {
        let name = String(listing.preferenceKey.prefix(while: { $0 != "|" }))
        let reviewedBuildings = liked.union(noped).map { String($0.prefix(while: { $0 != "|" })) }
        return Set(reviewedBuildings).contains(name)
    }

    func setPreference(_ key: String, preference: BuildingPreferenceStore.Preference) async {
        switch preference {
        case .like: liked.insert(key); noped.remove(key)
        case .nope: noped.insert(key); liked.remove(key)
        }
    }

    func removePreference(_ key: String) async {
        liked.remove(key)
        noped.remove(key)
    }
}
