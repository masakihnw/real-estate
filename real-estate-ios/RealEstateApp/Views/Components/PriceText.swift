import SwiftUI

/// 物件価格の統一表示コンポーネント。
///
/// フォーマットロジックは `Listing.formatPriceCompact` と同一アルゴリズムを使用。
/// `format(_:)` / `formatShort(_:)` は static で公開しているため、
/// View 以外（テスト・ViewModel）からも呼べる。
struct PriceText: View {
    let priceMan: Int
    var style: Style = .full

    enum Style {
        /// "1億2,300万円" — 詳細・一覧行
        case full
        /// "1億2,300万" — コンパクト表示（万のみ、円なし）
        case compact
        /// largeTitle.bold() — ヒーロー価格（詳細1画面目）
        case hero
    }

    var body: some View {
        switch style {
        case .full:
            Text(Self.format(priceMan))
                .font(DS.Typography.body)
                .fontWeight(.bold)
        case .compact:
            Text(Self.formatShort(priceMan))
                .font(DS.Typography.label)
                .fontWeight(.bold)
        case .hero:
            Text(Self.format(priceMan))
                .font(DS.Typography.hero)
        }
    }

    // MARK: - Static formatters

    private static let decimalStyle = IntegerFormatStyle<Int>.number
        .locale(Locale(identifier: "en_US_POSIX"))

    /// "万円" 付き表示。`Listing.formatPriceCompact` と同一結果を返す。
    static func format(_ priceMan: Int) -> String {
        formatInternal(priceMan, unit: "万円")
    }

    /// "万" のみ（円なし）。一覧カード等のコンパクト表示用。
    static func formatShort(_ priceMan: Int) -> String {
        formatInternal(priceMan, unit: "万")
    }

    private static func formatInternal(_ man: Int, unit: String) -> String {
        if man >= 10_000 {
            let oku = man / 10_000
            let remainder = man % 10_000
            if remainder == 0 {
                return "\(oku)億"
            }
            return "\(oku)億\(remainder.formatted(decimalStyle))\(unit)"
        }
        return "\(man.formatted(decimalStyle))\(unit)"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: DS.Spacing.md) {
        PriceText(priceMan: 9_800)
        PriceText(priceMan: 12_300)
        PriceText(priceMan: 10_000)
        PriceText(priceMan: 9_800, style: .compact)
        PriceText(priceMan: 12_300, style: .compact)
        PriceText(priceMan: 12_300, style: .hero)
    }
    .padding()
}
