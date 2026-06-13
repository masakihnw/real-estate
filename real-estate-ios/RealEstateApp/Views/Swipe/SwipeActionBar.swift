import SwiftUI

struct SwipeActionBar: View {
    let onNope: () -> Void
    let onSkip: () -> Void
    let onUndo: () -> Void
    let onLike: () -> Void
    let canUndo: Bool

    var body: some View {
        // ハプティクスは確定経路（SwipeSessionView.commitWithAnimation / onUndo）に
        // 一元化済み。ボタン・ジェスチャ両経路で同一・二重発火しないようここでは鳴らさない。
        HStack(spacing: 24) {
            actionButton(
                systemImage: "xmark",
                color: .orange,
                size: 56,
                action: onNope
            )

            actionButton(
                systemImage: "arrow.down",
                color: .gray,
                size: 44,
                action: onSkip
            )

            actionButton(
                systemImage: "arrow.uturn.backward",
                color: canUndo ? .gray : .gray.opacity(0.3),
                size: 44,
                action: {
                    guard canUndo else { return }
                    onUndo()
                }
            )
            .disabled(!canUndo)

            actionButton(
                systemImage: "heart.fill",
                color: .yellow,
                size: 56,
                action: onLike
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
        case "arrow.down": "あとで"
        case "arrow.uturn.backward": "元に戻す"
        case "heart.fill": "Like"
        default: ""
        }
    }
}
