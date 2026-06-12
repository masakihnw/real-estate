import SwiftUI

/// セクションコンテナ。見出し＋折りたたみ対応＋Glass 背景。
///
/// 詳細画面・ダッシュボード等のセクションの台紙として使う。
/// `isCollapsible: true` にすると見出しタップで展開/折りたたみができる。
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var isCollapsible: Bool = false
    let initiallyExpanded: Bool
    @State private var isExpanded: Bool = true
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        systemImage: String? = nil,
        isCollapsible: Bool = false,
        initiallyExpanded: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isCollapsible = isCollapsible
        self.initiallyExpanded = initiallyExpanded
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            headerRow
            if isExpanded {
                Group { content() }
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    )
            }
        }
        .padding(DS.Spacing.md)
        .cardGlassBackground()
        .cardShadow()
    }

    private var headerRow: some View {
        Button {
            guard isCollapsible else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: DS.Spacing.sm - 2) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(DS.Typography.label)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(DS.Typography.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer()
                if isCollapsible {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(DS.Typography.label)
                        .foregroundStyle(.secondary)
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(isCollapsible ? (isExpanded ? "タップで折りたたむ" : "タップで展開する") : "")
    }
}

#Preview {
    ScrollView {
        VStack(spacing: DS.Spacing.lg) {
            SectionCard(title: "物件スペック", systemImage: "doc.text") {
                VStack(spacing: DS.Spacing.sm) {
                    Text("3LDK / 82㎡ / 築38年").font(DS.Typography.body)
                    Text("渋谷区広尾4丁目").font(DS.Typography.label).foregroundStyle(.secondary)
                }
            }

            SectionCard(
                title: "価格履歴",
                systemImage: "chart.line.downtrend.xyaxis",
                isCollapsible: true
            ) {
                Text("2024/03: 1億2,500万 → 2024/06: 1億2,300万")
                    .font(DS.Typography.label)
                    .foregroundStyle(.secondary)
            }

            SectionCard(
                title: "初期折りたたみ",
                isCollapsible: true,
                initiallyExpanded: false
            ) {
                Text("展開後に表示されるコンテンツ")
                    .font(DS.Typography.body)
            }
        }
        .padding(DS.Spacing.lg)
    }
}
