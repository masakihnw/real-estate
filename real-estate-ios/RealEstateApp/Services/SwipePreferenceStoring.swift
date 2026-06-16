import Foundation

/// スワイプセッションが必要とする like/nope 設定ストアの最小インターフェース。
///
/// `SwipeSessionViewModel` をこの抽象に依存させることで、ユニットテストでは
/// ネットワーク（Supabase）へ書き込まないモックを注入できる。
/// 本番は `BuildingPreferenceStore.shared` をそのまま使う。
@MainActor
protocol SwipePreferenceStoring {
    func isBuildingReviewed(_ listing: Listing) -> Bool
    func setPreference(_ key: String, preference: BuildingPreferenceStore.Preference) async
    func removePreference(_ key: String) async
}

extension BuildingPreferenceStore: SwipePreferenceStoring {}
