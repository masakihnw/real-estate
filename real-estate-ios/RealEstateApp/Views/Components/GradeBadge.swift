import SwiftUI

/// グレード（S〜D）表示バッジ。ScoreBadge の後継。
///
/// - 新規コードはこちらを使うこと（ScoreBadge は既存画面との互換のため保留）。
/// - `score` を渡すとカプセル型（グレード＋数値）、省略すると正方形（グレードのみ）。
/// - アクセシビリティラベルで色のみに依存しないよう VoiceOver 対応済み。
struct GradeBadge: View {
    let grade: String
    var score: Int? = nil
    var size: BadgeSize = .medium

    enum BadgeSize {
        case small, medium, large

        var side: CGFloat {
            switch self {
            case .small:  22
            case .medium: 30
            case .large:  38
            }
        }

        var gradeFont: Font {
            switch self {
            case .small:  DS.Typography.badge
            case .medium: .caption.weight(.black)
            case .large:  .subheadline.weight(.black)
            }
        }
    }

    private var color: Color { DesignSystem.scoreColor(for: grade) }

    var body: some View {
        if let score {
            capsuleView(score: score)
        } else {
            squareView
        }
    }

    // MARK: - Private variants

    private var squareView: some View {
        Text(grade)
            .font(size.gradeFont)
            .foregroundStyle(.white)
            .frame(width: size.side, height: size.side)
            .background(color)
            .clipShape(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
            )
            .accessibilityLabel("評価\(grade)")
    }

    private func capsuleView(score: Int) -> some View {
        HStack(spacing: DS.Spacing.xs - 1) {
            Text(grade)
                .font(DS.Typography.label.weight(.black))
            Text("\(score)")
                .font(DS.Typography.label.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(color)
        .clipShape(Capsule())
        .accessibilityLabel("評価\(grade)、スコア\(score)")
    }
}

#Preview {
    VStack(spacing: DS.Spacing.md) {
        HStack(spacing: DS.Spacing.sm) {
            GradeBadge(grade: "S")
            GradeBadge(grade: "A")
            GradeBadge(grade: "B")
            GradeBadge(grade: "C")
            GradeBadge(grade: "D")
        }
        HStack(spacing: DS.Spacing.sm) {
            GradeBadge(grade: "S", score: 86)
            GradeBadge(grade: "A", score: 72)
            GradeBadge(grade: "B", score: 58)
        }
        HStack(spacing: DS.Spacing.sm) {
            GradeBadge(grade: "S", size: .small)
            GradeBadge(grade: "A", size: .large)
        }
    }
    .padding()
}
