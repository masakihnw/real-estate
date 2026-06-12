import SwiftUI

/// 価格変動バッジ（▼200万 / ▲120万）。
///
/// 値下げ = DesignSystem.priceDownColor（青）、値上がり = priceUpColor（オレンジ）。
/// `baseMan` を渡すとパーセンテージも表示する。
struct DeltaBadge: View {
    /// 変動額（万円単位）。負 = 値下がり、正 = 値上がり。
    let deltaMan: Int
    /// パーセント表示に使う基準価格（万円）。nil の場合はパーセント非表示。
    var baseMan: Int? = nil

    private var isDown: Bool { deltaMan < 0 }
    private var color: Color { isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor }
    private var arrow: String { isDown ? "▼" : "▲" }
    private var absAmount: Int { abs(deltaMan) }

    @ViewBuilder
    var body: some View {
        if deltaMan != 0 {
            label
                .font(DS.Typography.badge)
                .foregroundStyle(color)
                .padding(.horizontal, DS.Spacing.sm - 1)
                .padding(.vertical, DS.Spacing.xs - 1)
                .background(color.opacity(DS.Opacity.tintBg))
                .clipShape(
                    RoundedRectangle(cornerRadius: DS.Radius.chip - 2, style: .continuous)
                )
                .accessibilityLabel(a11yLabel)
        }
    }

    private var a11yLabel: String {
        let direction = isDown ? "値下げ" : "値上がり"
        if let base = baseMan, base > 0 {
            let pct = abs(Double(deltaMan) / Double(base) * 100)
            return "\(direction)\(absAmount)万円、\(String(format: "%.1f", pct))パーセント"
        }
        return "\(direction)\(absAmount)万円"
    }

    @ViewBuilder
    private var label: some View {
        if let base = baseMan, base > 0 {
            let pct = abs(Double(deltaMan) / Double(base) * 100)
            Text("\(arrow)\(absAmount)万 (\(String(format: "%.1f", pct))%)")
        } else {
            Text("\(arrow)\(absAmount)万")
        }
    }
}

#Preview {
    VStack(spacing: DS.Spacing.md) {
        DeltaBadge(deltaMan: -200)
        DeltaBadge(deltaMan: -200, baseMan: 12_500)
        DeltaBadge(deltaMan: 120)
        DeltaBadge(deltaMan: 120, baseMan: 9_480)
    }
    .padding()
}
