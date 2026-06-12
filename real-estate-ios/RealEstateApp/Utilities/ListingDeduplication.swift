import Foundation

/// 建物単位の重複排除ロジック。
///
/// 旧 DashboardView の static メソッドから移設（DashboardView は Today タブ刷新で廃止）。
/// TodayDigest と DuplicateDeduplicationTests から参照される単一実装。
enum ListingDeduplication {

    /// 新着物件を addedAt 降順に並べ、同一建物（buildingGroupKey）の重複を排除する。
    /// `prefStore` を渡すと評価済み（like/nope）建物も除外する。
    @MainActor
    static func deduplicatedNewListings(
        _ listings: [Listing],
        prefStore: BuildingPreferenceStore? = nil
    ) -> [Listing] {
        var seen = Set<String>()
        return listings
            .sorted { $0.addedAt > $1.addedAt }
            .filter { listing in
                if let pref = prefStore, pref.isBuildingReviewed(listing) { return false }
                return seen.insert(listing.buildingGroupKey).inserted
            }
    }
}
