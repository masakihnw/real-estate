//
//  DesignSystem.swift
//  RealEstateApp
//
//  HIG（Human Interface Guidelines）・OOUI に則ったスタイル。
//  iOS 26+: Liquid Glass（.glassEffect）を適用（#available による機能可用性チェック）。
//  iOS 17–25: .ultraThinMaterial でフォールバック。
//

import SwiftUI

// MARK: - HIG: セマンティックな余白・形状

enum DesignSystem {
    /// リスト行の内側余白（HIG: Content margins）
    static let listRowVerticalPadding: CGFloat = 12
    static let listRowHorizontalPadding: CGFloat = 16
    /// カード／セクションの角丸（HIG: Consistent corner radius）
    static let cornerRadius: CGFloat = 12
    static let cornerRadiusContinuous: CGFloat = 12
    /// 詳細画面のグリッド・カード間隔
    static let detailGridSpacing: CGFloat = 16
    static let detailSectionSpacing: CGFloat = 20

    // MARK: - Semantic Colors (D1, D4, D5)

    /// 新築物件の価格色
    static let shinchikuPriceColor = Color(red: 0.204, green: 0.78, blue: 0.349)
    /// 値上がり/プラス色
    static let positiveColor = Color(red: 0.204, green: 0.78, blue: 0.349)
    /// 値下がり/マイナス色
    static let negativeColor = Color.red

    /// 価格変動: 値下がり色（ブルー）
    static let priceDownColor = Color(red: 0.18, green: 0.53, blue: 0.76)
    /// 価格変動: 値上がり色（オレンジ）
    static let priceUpColor = Color(red: 0.90, green: 0.49, blue: 0.13)

    /// 通勤バッジ: Playground 社カラー
    static let commutePGColor = Color(red: 0.0, green: 0.48, blue: 1.0)
    /// 通勤バッジ: M3Career 社カラー
    static let commuteM3Color = Color(red: 0.55, green: 0.24, blue: 0.78)

    // MARK: - AI Accent (Claude生成コンテンツ用)

    static let aiAccent = Color(red: 0.345, green: 0.337, blue: 0.839)
    static let aiAccentTint = Color(red: 0.345, green: 0.337, blue: 0.839).opacity(0.10)
    static let aiAccentBorder = Color(red: 0.345, green: 0.337, blue: 0.839).opacity(0.22)

    // MARK: - Score Grades (S/A/B/C/D)

    static let scoreS = Color(red: 1.0, green: 0.7, blue: 0.0)
    static let scoreA = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let scoreB = Color(red: 0.204, green: 0.78, blue: 0.349)
    static let scoreC = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let scoreD = Color.red

    static func scoreColor(for grade: String) -> Color {
        switch grade {
        case "S": return scoreS
        case "A": return scoreA
        case "B": return scoreB
        case "C": return scoreC
        case "D": return scoreD
        default: return scoreC
        }
    }

    // MARK: - Source / Portal Colors

    static let srcSuumo = Color(red: 0.0, green: 0.592, blue: 0.231)
    static let srcHomes = Color(red: 0.949, green: 0.588, blue: 0.0)
    static let srcRehouse = Color(red: 0.784, green: 0.063, blue: 0.18)
    static let srcNomucom = Color(red: 0.0, green: 0.247, blue: 0.533)
    static let srcAthome = Color(red: 0.9, green: 0.0, blue: 0.071)
    static let srcStepon = Color(red: 0.122, green: 0.306, blue: 0.616)
    static let srcLivable = Color(red: 0.0, green: 0.604, blue: 0.267)

    // MARK: - Hazard Severity

    static let hazardHigh = Color.red
    static let hazardMid = Color.orange
    static let hazardLow = Color.yellow

    // MARK: - Monthly Payment Defaults

    static let monthlyPaymentRate: Double = 1.2
    static let monthlyPaymentYears: Int = 50
    static let purchaseFeeMultiplier: Double = 1.065
}

// MARK: - カード背景色（プロンプト準拠）

extension Color {
    /// カード/セクション背景: Color(white: 0.973) ≈ #F8F8FB
    static let cardBackground = Color(white: 0.973)
}

// MARK: - Liquid Glass (iOS 26+) / Material fallback (iOS 17–25)

extension View {
    /// カード用の背景。iOS 26+ では Liquid Glass、それ以前はセマンティックカラー。
    /// ダークモードでは #1C1C1E (secondarySystemGroupedBackground) に自動適応。
    @ViewBuilder
    func listingGlassBackground() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.cornerRadius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    /// リスト行背景用。iOS 26+ では Liquid Glass、それ以前はセマンティックカラー。
    @ViewBuilder
    func listingRowGlassBackground() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.cornerRadius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    /// 色付きティント付きの Glass 背景。セクションの種類を色で区別する。
    /// iOS 26+: Glass + 薄いカラーオーバーレイ
    /// iOS 17–25: カラー背景 + ボーダー
    @ViewBuilder
    func tintedGlassBackground(tint: Color, tintOpacity: Double = 0.04, borderOpacity: Double = 0.12) -> some View {
        if #available(iOS 26, *) {
            self.background(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .fill(tint.opacity(tintOpacity))
            )
            .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.cornerRadius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .fill(tint.opacity(tintOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .stroke(tint.opacity(borderOpacity), lineWidth: 1)
            )
        }
    }
}

// MARK: - OOUI: オブジェクト（物件）の一貫した表現

/// 物件オブジェクトの行・カードで使うフォント・階層（HIG: Typography, Dynamic Type）
struct ListingObjectStyle {
    static let title = Font.headline
    static let subtitle = Font.subheadline
    static let caption = Font.caption
    static let detailValue = Font.subheadline
    static let detailLabel = Font.caption
}
