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
                        DetailItem(title: "築年", value: listing.builtDisplay)
                        DetailItem(title: "駅徒歩", value: listing.walkDisplay)
                        DetailItem(title: "所在階", value: listing.floorPosition.map { "\($0)階" } ?? "—")
                        DetailItem(title: "階建", value: listing.floorTotal.map { "\($0)階建" } ?? "—")
                        DetailItem(title: "総戸数", value: listing.totalUnits.map { "\($0)戸" } ?? "—")
                    }

                    if let line = listing.stationLine, !line.isEmpty {
                        DetailItem(title: "路線・駅", value: line)
                    }
                    if let ownership = listing.ownership, !ownership.isEmpty {
                        DetailItem(title: "権利形態", value: ownership)
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
