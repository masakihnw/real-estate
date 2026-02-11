//
//  ListingDetailView.swift
//  RealEstateApp
//
//  HIG・OOUI: 物件オブジェクトの詳細。名詞（物件）を選択したあとの属性表示と、動詞（詳細を開く）アクション。
//

import SwiftUI
import SwiftData

struct ListingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let listing: Listing
    @State private var editableMemo: String = ""
    @FocusState private var isMemoFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.detailSectionSpacing) {
                    // オブジェクトの識別: 名前・住所 ＋ いいね
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(listing.name)
                                .font(.title2)
                                .fontWeight(.semibold)
                            if let addr = listing.address, !addr.isEmpty {
                                Text(addr)
                                    .font(ListingObjectStyle.subtitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                        Button {
                            listing.isLiked.toggle()
                            saveContext()
                            FirebaseSyncService.shared.pushAnnotation(for: listing)
                        } label: {
                            Image(systemName: listing.isLiked ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(listing.isLiked ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(listing.isLiked ? "いいねを解除" : "いいねする")
                    }
                    .accessibilityElement(children: .combine)

                    Divider()

                    // メモ・コメント
                    VStack(alignment: .leading, spacing: 6) {
                        Text("メモ")
                            .font(ListingObjectStyle.detailLabel)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $editableMemo)
                            .font(ListingObjectStyle.detailValue)
                            .frame(minHeight: 80)
                            .padding(8)
                            .listingGlassBackground()
                            .focused($isMemoFocused)
                            .onChange(of: editableMemo) { _, newValue in
                                listing.memo = newValue.isEmpty ? nil : newValue
                                saveContext()
                                FirebaseSyncService.shared.pushAnnotation(for: listing)
                            }
                    }

                    Divider()

                    // 属性グリッド（OOUI: オブジェクトのプロパティ）
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: DesignSystem.detailGridSpacing) {
                        DetailItem(title: "価格", value: listing.priceDisplay)
                        DetailItem(title: "専有面積", value: listing.areaDisplay)
                        DetailItem(title: "間取り", value: listing.layout ?? "—")
                        if listing.isShinchiku {
                            DetailItem(title: "引渡時期", value: listing.deliveryDateDisplay)
                        } else {
                            DetailItem(title: "築年", value: listing.builtDisplay)
                            DetailItem(title: "所在階", value: listing.floorPosition.map { "\($0)階" } ?? "—")
                        }
                        DetailItem(title: "駅徒歩", value: listing.walkDisplay)
                        DetailItem(title: "階建", value: listing.floorTotal.map { "\($0)階建" } ?? "—")
                        DetailItem(title: "総戸数", value: listing.totalUnits.map { "\($0)戸" } ?? "—")
                        DetailItem(title: "種別", value: listing.isShinchiku ? "新築" : "中古")
                    }

                    if let line = listing.stationLine, !line.isEmpty {
                        DetailItem(title: "路線・駅", value: line)
                    }
                    if let ownership = listing.ownership, !ownership.isEmpty {
                        DetailItem(title: "権利形態", value: ownership)
                    }

                    // 住まいサーフィン評価セクション
                    if listing.hasSumaiSurfinData {
                        Divider()
                        sumaiSurfinSection
                    }

                    Divider()

                    // 動詞: 詳細を開く（OOUI: オブジェクトに対するアクション）
                    if let url = URL(string: listing.url) {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "safari")
                                Text("SUUMO/HOME'S で詳細を開く")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("SUUMO または HOME'S で詳細を開く")
                    }

                    // 住まいサーフィンへのリンク
                    if let ssURL = listing.ssSumaiSurfinURL,
                       let url = URL(string: ssURL) {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "chart.bar.xaxis")
                                Text("住まいサーフィンで詳しく見る")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("住まいサーフィンで詳しく見る")
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onAppear {
                editableMemo = listing.memo ?? ""
            }
        }
    }

    // MARK: - 住まいサーフィン評価セクション

    @ViewBuilder
    private var sumaiSurfinSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // セクションヘッダー
            Label("住まいサーフィン評価", systemImage: "chart.bar.xaxis")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)

            // 儲かる確率（大きく表示）
            if let pct = listing.ssProfitPct {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("沖式儲かる確率")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(pct)")
                                .font(.system(size: 36, weight: .heavy, design: .rounded))
                                .foregroundStyle(profitColor(pct))
                            Text("%")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundStyle(profitColor(pct))
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if let price = listing.ssOkiPrice70m2 {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(listing.isShinchiku ? "沖式新築時価" : "沖式時価")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(price)万円")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                        }
                        if let judgment = listing.ssValueJudgment {
                            Text(judgment)
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(judgmentColor(judgment).opacity(0.15))
                                .foregroundStyle(judgmentColor(judgment))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            } else if let price = listing.ssOkiPrice70m2 {
                // 儲かる確率がない場合でも沖式時価があれば表示
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(listing.isShinchiku ? "沖式新築時価" : "沖式時価")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(price)万円")
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    Spacer()
                    if let judgment = listing.ssValueJudgment {
                        Text(judgment)
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(judgmentColor(judgment).opacity(0.15))
                            .foregroundStyle(judgmentColor(judgment))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            // ランキング
            if listing.ssStationRank != nil || listing.ssWardRank != nil {
                HStack(spacing: 16) {
                    if let stRank = listing.ssStationRank {
                        rankItem(label: "駅ランキング", value: stRank)
                    }
                    if let wRank = listing.ssWardRank {
                        rankItem(label: "区ランキング", value: wRank)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .listingGlassBackground()
    }

    private func rankItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            let parts = value.split(separator: "/")
            if parts.count == 2 {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(parts[0]))
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("/ \(parts[1])件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
    }

    private func profitColor(_ pct: Int) -> Color {
        if pct >= 70 { return .green }
        if pct >= 40 { return .orange }
        return .red
    }

    private func judgmentColor(_ judgment: String) -> Color {
        switch judgment {
        case "割安": return .green
        case "適正": return .secondary
        case "割高": return .red
        default: return .secondary
        }
    }

    private func saveContext() {
        try? modelContext.save()
    }
}

/// 詳細画面の1属性（ラベル＋値）。HIG: セマンティックな階層。背景は Material で Liquid Glass 風に。
private struct DetailItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ListingObjectStyle.detailLabel)
                .foregroundStyle(.secondary)
            Text(value)
                .font(ListingObjectStyle.detailValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .listingGlassBackground()
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Listing.self, configurations: config)
    let sample = Listing(
        url: "https://example.com/1",
        name: "サンプルマンション",
        priceMan: 8000,
        address: "東京都渋谷区〇〇1-2-3",
        stationLine: "JR山手線「原宿」徒歩6分",
        walkMin: 6,
        areaM2: 65,
        layout: "2LDK",
        builtYear: 2010,
        totalUnits: 100,
        floorPosition: 5,
        floorTotal: 10,
        ownership: "所有権"
    )
    container.mainContext.insert(sample)
    return ListingDetailView(listing: sample)
        .modelContainer(container)
}
