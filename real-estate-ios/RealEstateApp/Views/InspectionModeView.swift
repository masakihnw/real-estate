import SwiftUI
import SwiftData

/// 内見モード（提案 §5.6）。現地で見る前提の1画面に、ハザード・周辺相場・チェックリスト・
/// 内見写真・メモを集約する。既存データ（Listing 上の派生プロパティ）の再パッケージ。
/// 親（ListingDetailView）の NavigationStack へ push される前提で、自前の NavigationStack は持たない。
struct InspectionModeView: View {
    let listing: Listing
    @Environment(\.modelContext) private var modelContext
    @State private var newMemo = ""
    @State private var nearbyTxns: [TransactionRecord] = []
    @FocusState private var memoFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hazardCard
                marketCard
                checklistCard
                PhotoSectionView(listing: listing)
                memoCard
            }
            .padding()
        }
        .navigationTitle("内見モード")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // body 再評価ごとの SwiftData fetch を避けキャッシュ（成約レコードは画面内で不変）
            nearbyTxns = TransactionStore.nearby(address: listing.address, limit: 3, in: modelContext)
        }
    }

    // MARK: - ハザード

    private var hazardCard: some View {
        let hazard = listing.parsedHazardData
        return card("ハザード", icon: "exclamationmark.shield") {
            HStack(spacing: 8) {
                Image(systemName: safetyIcon(hazard.safetyLevel))
                    .foregroundStyle(safetyColor(hazard.safetyLevel))
                Text(safetyLabel(hazard.safetyLevel))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(safetyColor(hazard.safetyLevel))
            }
            if hazard.activeLabels.isEmpty {
                Text("重大なハザードリスクは確認されていません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(hazard.activeLabels.enumerated()), id: \.offset) { _, item in
                            HazardChip(icon: item.icon, label: item.label, severity: item.severity)
                        }
                    }
                }
            }
        }
    }

    private func safetyLabel(_ level: Listing.HazardSafetyLevel) -> String {
        switch level {
        case .safe: return "安全レベル: 高"
        case .lowRisk: return "安全レベル: 軽微なリスク"
        case .moderate: return "安全レベル: 要注意"
        case .elevated: return "安全レベル: 要確認"
        }
    }

    private func safetyColor(_ level: Listing.HazardSafetyLevel) -> Color {
        switch level {
        case .safe: return .green
        case .lowRisk: return .teal
        case .moderate: return .orange
        case .elevated: return .red
        }
    }

    private func safetyIcon(_ level: Listing.HazardSafetyLevel) -> String {
        switch level {
        case .safe: return "checkmark.shield.fill"
        case .lowRisk: return "shield.lefthalf.filled"
        case .moderate: return "exclamationmark.triangle.fill"
        case .elevated: return "exclamationmark.octagon.fill"
        }
    }

    // MARK: - 周辺相場

    private var marketCard: some View {
        let market = listing.parsedMarketData
        let txns = nearbyTxns
        return card("周辺相場", icon: "chart.bar") {
            if let market {
                HStack {
                    Text("相場比").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(market.priceRatioDisplay).font(.title3.weight(.bold))
                }
                HStack {
                    Text("相場差額").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(market.priceDiffDisplay).font(.subheadline.weight(.semibold))
                }
            }
            if txns.isEmpty {
                if market == nil {
                    Text("周辺の成約データがありません")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Divider()
                Text("周辺の成約事例").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(txns.enumerated()), id: \.offset) { _, tx in
                    HStack(spacing: 8) {
                        Text(tx.layout).font(.subheadline)
                        Text(String(format: "%.0f㎡", tx.areaM2)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(tx.priceMan)万円").font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(tx.tradePeriod).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - チェックリスト

    private var checklistCard: some View {
        let items = ChecklistMutation.display(listing.parsedChecklist)
        let checked = ChecklistMutation.checkedCount(listing.parsedChecklist)
        return card("内見チェックリスト（\(checked)/\(items.count)）", icon: "checklist") {
            ForEach(items) { item in
                Button {
                    toggleChecklist(item.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isChecked ? Color.green : Color.secondary)
                        Text(item.label)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggleChecklist(_ id: String) {
        let updated = ChecklistMutation.toggled(listing.parsedChecklist, itemId: id)
        listing.checklistJSON = ChecklistMutation.encode(updated)
        try? modelContext.save()
        HapticManager.soft()
    }

    // MARK: - メモ

    private var memoCard: some View {
        card("メモ", icon: "note.text") {
            let comments = listing.parsedComments
            if comments.isEmpty {
                Text("まだメモはありません")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.text).font(.subheadline)
                        Text("\(comment.authorName)・\(comment.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if AnnotationRouter.isAuthenticated {
                HStack(spacing: 8) {
                    TextField("現地メモを追加", text: $newMemo, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($memoFocused)
                    Button("追加") { addMemo() }
                        .disabled(newMemo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func addMemo() {
        let text = newMemo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AnnotationRouter.addComment(for: listing, text: text, modelContext: modelContext)
        newMemo = ""
        memoFocused = false
    }

    // MARK: - カード共通

    @ViewBuilder
    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
