import SwiftUI

struct SwipeActionBar: View {
    let onNope: () -> Void
    let onSkip: () -> Void
    let onUndo: () -> Void
    let onLike: () -> Void
    let canUndo: Bool

    var body: some View {
        HStack(spacing: 24) {
            actionButton(
                systemImage: "xmark",
                color: .orange,
                size: 56,
                action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onNope()
                }
            )

            actionButton(
                systemImage: "arrow.down",
                color: .gray,
                size: 44,
                action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSkip()
                }
            )

            actionButton(
                systemImage: "arrow.uturn.backward",
                color: canUndo ? .gray : .gray.opacity(0.3),
                size: 44,
                action: {
                    guard canUndo else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    onUndo()
                }
            )
            .disabled(!canUndo)

            actionButton(
                systemImage: "heart.fill",
                color: .yellow,
                size: 56,
                action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onLike()
                }
            )
        }
        .padding(.vertical, 12)
    }

    private func actionButton(
        systemImage: String,
        color: Color,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(.background)
                        .shadow(color: color.opacity(0.2), radius: 4, y: 2)
                )
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.3), lineWidth: 1.5)
                )
        }
        .accessibilityLabel(accessibilityLabelFor(systemImage))
    }

    private func accessibilityLabelFor(_ systemImage: String) -> String {
        switch systemImage {
        case "xmark": "Nope"
        case "arrow.down": "スキップ"
        case "arrow.uturn.backward": "元に戻す"
        case "heart.fill": "Like"
        default: ""
        }
    }
}
