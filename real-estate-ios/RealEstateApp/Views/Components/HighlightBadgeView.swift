import SwiftUI

struct HighlightBadgeView: View {
    let text: String
    var style: BadgeStyle = .accent

    enum BadgeStyle {
        case accent, positive, warning, neutral

        var backgroundColor: Color {
            switch self {
            case .accent: return .accentColor.opacity(0.12)
            case .positive: return DesignSystem.positiveColor.opacity(0.12)
            case .warning: return DesignSystem.negativeColor.opacity(0.12)
            case .neutral: return .secondary.opacity(0.08)
            }
        }

        var foregroundColor: Color {
            switch self {
            case .accent: return .accentColor
            case .positive: return DesignSystem.positiveColor
            case .warning: return DesignSystem.negativeColor
            case .neutral: return .secondary
            }
        }
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(style.backgroundColor)
            .foregroundStyle(style.foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    VStack(spacing: 8) {
        HighlightBadgeView(text: "築浅×駅2分")
        HighlightBadgeView(text: "含み益S", style: .positive)
        HighlightBadgeView(text: "値下げ注目", style: .warning)
        HighlightBadgeView(text: "再開発エリア", style: .neutral)
    }
    .padding()
}
