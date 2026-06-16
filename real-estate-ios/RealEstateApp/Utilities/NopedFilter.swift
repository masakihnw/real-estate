import Foundation

/// Nope（見送り）物件の絞り込みロジック。
///
/// `NopedListingsView` から利用。View から切り出した純関数なのでテスト可能。
enum NopedFilter {

    /// 全物件から noped キーに該当するものだけを返す。
    /// - Parameters:
    ///   - listings: 検索対象の全物件
    ///   - nopedKeys: `BuildingPreferenceStore.nopedKeys`（preferenceKey の集合）
    /// - Returns: noped な物件のみ（入力順を保持）
    static func filter(listings: [Listing], nopedKeys: Set<String>) -> [Listing] {
        listings.filter { nopedKeys.contains($0.preferenceKey) }
    }
}
