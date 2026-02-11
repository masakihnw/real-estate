//
//  DesignSystem.swift
//  RealEstateApp
//
//  HIG（Human Interface Guidelines）・OOUI に則ったスタイル。
//  iOS 26: Liquid Glass（.glassEffect）を適用。
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
}

// MARK: - Liquid Glass (iOS 26) / Material fallback (iOS 17–25)

extension View {
    /// カード用の背景。iOS 26 では Liquid Glass、それ以前はセマンティックカラー。
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

    /// リスト行背景用。iOS 26 では Liquid Glass、それ以前はセマンティックカラー。
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
