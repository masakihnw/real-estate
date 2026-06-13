import Foundation

/// スワイプセッションの進捗を永続化する。
///
/// 保持するのは2種類の identityKey 配列のみ:
/// - `remainingKeys`: 未消化デッキの並び（途中離脱→次回続きから）
/// - `skippedKeys`: 「あとで」した物件（次回デッキ先頭に再登場）
///
/// 時間ベースの期限は設けない。デッキ対象は `isRecentlyAdded`（2日窓）のため、
/// 古いキーは `SwipeDeckBuilder` が eligible 照合で自然に除外する。
/// `skippedKeys` の無限増殖は ViewModel 側が loadCards で eligible 内に剪定する。
///
/// テスト容易性のため UserDefaults を注入できる。
final class SwipeProgressStore {
    static let shared = SwipeProgressStore()

    private let defaults: UserDefaults
    private let remainingKey = "swipe.progress.remainingKeys"
    private let skippedKey = "swipe.progress.skippedKeys"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var remainingKeys: [String] {
        get { defaults.stringArray(forKey: remainingKey) ?? [] }
        set { defaults.set(newValue, forKey: remainingKey) }
    }

    var skippedKeys: [String] {
        get { defaults.stringArray(forKey: skippedKey) ?? [] }
        set { defaults.set(newValue, forKey: skippedKey) }
    }

    /// デッキ完走時に呼ぶ。残りデッキはクリアするが、未決の「あとで」は次回先頭
    /// 再登場のため保持する。
    func clearRemaining() {
        defaults.removeObject(forKey: remainingKey)
    }

    /// 全進捗をリセット（テスト・デバッグ用）。
    func clearAll() {
        defaults.removeObject(forKey: remainingKey)
        defaults.removeObject(forKey: skippedKey)
    }
}
