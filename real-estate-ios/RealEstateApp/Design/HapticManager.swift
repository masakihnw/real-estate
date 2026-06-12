import UIKit

/// 触覚フィードバックの一元化ヘルパー。
///
/// - SwiftUI View からは `.sensoryFeedback()` modifier を直接使うこと。
/// - この型は ViewModel 等の非 View コンテキストで呼ぶ際のヘルパー。
/// - Mac Catalyst では haptic API が存在しないため `#if os(iOS)` でガード済み。
struct HapticManager {
    private init() {}

    /// ハプティクスを事前ウォームアップする。遅延が気になる箇所（カードロード直後など）で呼ぶ。
    static func prepare(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
#if os(iOS)
        UIImpactFeedbackGenerator(style: style).prepare()
#endif
    }

    /// 汎用 impact（スワイプ Like/Nope、主要ボタン操作）
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
#if os(iOS)
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
#endif
    }

    /// 軽いタッチ（カード出現、バッジタップ）
    static func soft() {
#if os(iOS)
        let gen = UIImpactFeedbackGenerator(style: .soft)
        gen.prepare()
        gen.impactOccurred()
#endif
    }

    /// 成功通知（保存完了、Like確定）
    static func success() {
#if os(iOS)
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.success)
#endif
    }

    /// エラー通知（操作失敗）
    static func error() {
#if os(iOS)
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.error)
#endif
    }
}
