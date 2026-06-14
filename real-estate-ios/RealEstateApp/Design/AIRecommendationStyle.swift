import SwiftUI

/// AI購入推奨フラグの意味づけ（色マッピングの前段。純粋な分類なのでテスト可能）。
enum RecommendationFlagSentiment {
    case positive
    case negative
    case caution
    case neutral
}

/// AI購入推奨の表示スタイルを一元管理する。
///
/// スコア→ラベル/色、フラグ→意味づけ/色 のロジックは
/// `InvestmentSummaryCard` / `SwipeCardView` / `ListingListView` で重複していたため、
/// ここに純関数として集約する（判定ロジックは `AIRecommendationStyleTests` で固定）。
enum AIRecommendationStyle {

    /// スコア(1-5)に対応する日本語ラベル。範囲外/nil は空文字。
    static func label(forScore score: Int?) -> String {
        switch score {
        case 5: return "強く推奨"
        case 4: return "推奨"
        case 3: return "条件次第"
        case 2: return "非推奨"
        case 1: return "見送り"
        default: return ""
        }
    }

    /// フラグ文字列の意味づけ。否定・注意キーワードを肯定マーカーより優先する。
    static func sentiment(forFlag flag: String) -> RecommendationFlagSentiment {
        if flag.contains("リスク") || flag.contains("NG") || flag.contains("不足") {
            return .negative
        }
        if flag.contains("注意") || flag.contains("不透明") {
            return .caution
        }
        if flag.hasSuffix("◎") || flag.hasSuffix("○") {
            return .positive
        }
        return .neutral
    }

    /// スコアに対応する星・ラベルの色。
    static func starColor(forScore score: Int?) -> Color {
        switch score {
        case 5: return .green
        case 4: return .blue
        case 3: return .orange
        default: return .secondary
        }
    }

    /// 推奨カードの枠線色（スコアに応じて淡く色付け）。
    static func borderColor(forScore score: Int?) -> Color {
        switch score {
        case 5: return .green.opacity(0.3)
        case 4: return .blue.opacity(0.3)
        case 3: return .orange.opacity(0.3)
        default: return Color.secondary.opacity(0.15)
        }
    }

    /// 意味づけに対応する色。
    static func color(for sentiment: RecommendationFlagSentiment) -> Color {
        switch sentiment {
        case .positive: return .green
        case .negative: return .red
        case .caution: return .orange
        case .neutral: return .secondary
        }
    }

    /// フラグ文字列に対応する色（`sentiment(forFlag:)` 経由）。
    static func flagColor(for flag: String) -> Color {
        color(for: sentiment(forFlag: flag))
    }
}
