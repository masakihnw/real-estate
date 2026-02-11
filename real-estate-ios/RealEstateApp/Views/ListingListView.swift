//
//  ListingListView.swift
//  RealEstateApp
//
//  HIG・OOUI に則った一覧。オブジェクト＝物件（Listing）を一覧し、タップで詳細へ（名詞→動詞）。
//

import SwiftUI
import SwiftData

// MARK: - Filter State

enum OwnershipType: String, CaseIterable, Hashable {
    case ownership = "所有権"
    case leasehold = "定期借地"
}

struct ListingFilter: Equatable {
    var priceMin: Int? = nil              // 万円
    var priceMax: Int? = nil              // 万円
    var layouts: Set<String> = []         // 空 = 全て
    var stations: Set<String> = []        // 空 = 全て（駅名）
    var walkMax: Int? = nil               // 分以内
    var areaMin: Double? = nil            // ㎡以上
    var ownershipTypes: Set<OwnershipType> = []  // 空 = 全て

    var isActive: Bool {
        priceMin != nil || priceMax != nil || !layouts.isEmpty || !stations.isEmpty || walkMax != nil || areaMin != nil || !ownershipTypes.isEmpty
    }

    mutating func reset() {
        priceMin = nil; priceMax = nil; layouts = []; stations = []; walkMax = nil; areaMin = nil; ownershipTypes = []
    }
}

struct ListingListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ListingStore.self) private var store
    @Query(sort: \Listing.priceMan, order: .forward) private var listings: [Listing]
    @State private var sortOrder: SortOrder = .addedDesc
    @State private var selectedListing: Listing?
    @State private var filter = ListingFilter()
    @State private var showFilterSheet = false

    /// true のとき、いいね済みの物件だけ表示する（お気に入りタブ用）
    var favoritesOnly: Bool = false

    /// 物件種別フィルタ: nil = 全て、"chuko" = 中古のみ、"shinchiku" = 新築のみ
    var propertyTypeFilter: String? = nil

    enum SortOrder: String, CaseIterable {
        case addedDesc = "追加日（新しい順）"
        case priceAsc = "価格の安い順"
        case priceDesc = "価格の高い順"
        case walkAsc = "徒歩の近い順"
        case areaDesc = "広い順"
    }

    private var baseList: [Listing] {
        var list: [Listing]
        if favoritesOnly {
            list = listings.filter(\.isLiked)
        } else if let pt = propertyTypeFilter {
            list = listings.filter { $0.propertyType == pt }
        } else {
            list = Array(listings)
        }
        return list
    }

    var filteredAndSorted: [Listing] {
        var list = baseList

        // フィルタ
        if let min = filter.priceMin {
            list = list.filter { ($0.priceMan ?? 0) >= min }
        }
        if let max = filter.priceMax {
            list = list.filter { ($0.priceMan ?? Int.max) <= max }
        }
        if !filter.layouts.isEmpty {
            list = list.filter { filter.layouts.contains($0.layout ?? "") }
        }
        if !filter.stations.isEmpty {
            list = list.filter { filter.stations.contains($0.stationName ?? "") }
        }
        if let max = filter.walkMax {
            list = list.filter { ($0.walkMin ?? 99) <= max }
        }
        if let min = filter.areaMin {
            list = list.filter { ($0.areaM2 ?? 0) >= min }
        }
        if !filter.ownershipTypes.isEmpty {
            list = list.filter { listing in
                let o = listing.ownership ?? ""
                return filter.ownershipTypes.contains { type in
                    switch type {
                    case .ownership: return o.contains("所有権")
                    case .leasehold: return o.contains("借地")
                    }
                }
            }
        }

        // ソート
        switch sortOrder {
        case .addedDesc:
            list.sort { $0.addedAt > $1.addedAt }
        case .priceAsc:
            list.sort { ($0.priceMan ?? 0) < ($1.priceMan ?? 0) }
        case .priceDesc:
            list.sort { ($0.priceMan ?? 0) > ($1.priceMan ?? 0) }
        case .walkAsc:
            list.sort { ($0.walkMin ?? 99) < ($1.walkMin ?? 99) }
        case .areaDesc:
            list.sort { ($0.areaM2 ?? 0) > ($1.areaM2 ?? 0) }
        }
        return list
    }

    private var navTitle: String {
        if favoritesOnly { return "お気に入り" }
        switch propertyTypeFilter {
        case "shinchiku": return "新築マンション"
        case "chuko": return "中古マンション"
        default: return "物件一覧"
        }
    }

    /// 一覧内に存在する間取りの一意リスト（フィルタシートの選択肢用）
    private var availableLayouts: [String] {
        let all = Set(baseList.compactMap(\.layout).filter { !$0.isEmpty })
        return all.sorted()
    }

    /// 一覧内に存在する駅名を路線ごとにグルーピング（フィルタシートの選択肢用）
    private var stationsByLine: [(line: String, stations: [String])] {
        var dict: [String: Set<String>] = [:]
        for listing in baseList {
            guard let lineName = listing.lineName,
                  let stationName = listing.stationName else { continue }
            dict[lineName, default: []].insert(stationName)
        }
        return dict.keys.sorted().map { key in
            (line: key, stations: dict[key]!.sorted())
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if baseList.isEmpty && !store.isRefreshing {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle(navTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await store.refresh(modelContext: modelContext) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing || store.listURL.isEmpty)
                        .accessibilityLabel("更新")

                        Button {
                            showFilterSheet = true
                        } label: {
                            Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("フィルタ")

                        Menu {
                            ForEach(SortOrder.allCases, id: \.self) { order in
                                Button(order.rawValue) { sortOrder = order }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle")
                        }
                        .accessibilityLabel("並び順")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if let err = store.lastError {
                        Text(err)
                            .font(ListingObjectStyle.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .refreshable {
                await store.refresh(modelContext: modelContext)
            }
            .sheet(item: $selectedListing) { listing in
                ListingDetailView(listing: listing)
            }
            .sheet(isPresented: $showFilterSheet) {
                ListingFilterSheet(filter: $filter, availableLayouts: availableLayouts, stationsByLine: stationsByLine)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                favoritesOnly ? "お気に入りがありません" : "物件がありません",
                systemImage: favoritesOnly ? "heart.slash" : "building.2"
            )
        } description: {
            Text(
                favoritesOnly
                    ? "物件一覧でハートをタップするとここに表示されます。"
                    : "「設定」タブで一覧JSONのURLを入力し、保存後に更新ボタンを押してください。"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var listContent: some View {
        List {
            Section {
                HStack {
                    if filter.isActive {
                        Text("\(filteredAndSorted.count)/\(baseList.count)件")
                            .font(ListingObjectStyle.subtitle)
                            .foregroundStyle(.primary)
                        Button("リセット") { filter.reset() }
                            .font(ListingObjectStyle.caption)
                    }
                    Spacer()
                    if let at = store.lastFetchedAt {
                        Text("更新 ")
                            .font(ListingObjectStyle.caption)
                            .foregroundStyle(.secondary) +
                        Text(at, style: .relative)
                            .font(ListingObjectStyle.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(filteredAndSorted, id: \.url) { listing in
                ListingRowView(
                    listing: listing,
                    onTap: { selectedListing = listing },
                    onLikeTapped: {
                        listing.isLiked.toggle()
                        try? modelContext.save()
                        FirebaseSyncService.shared.pushAnnotation(for: listing)
                    }
                )
                .listRowInsets(EdgeInsets(
                    top: DesignSystem.listRowVerticalPadding,
                    leading: DesignSystem.listRowHorizontalPadding,
                    bottom: DesignSystem.listRowVerticalPadding,
                    trailing: DesignSystem.listRowHorizontalPadding
                ))
                .listRowBackground(
                    ListingRowBackground()
                        .padding(.horizontal, DesignSystem.listRowHorizontalPadding * 0.5)
                        .padding(.vertical, 2)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: listing))
                .accessibilityHint("タップで詳細。ハートでいいね")
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.isRefreshing {
                ProgressView("更新中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private func accessibilityLabel(for listing: Listing) -> String {
        "\(listing.name)、\(listing.priceDisplay)、\(listing.areaDisplay)、\(listing.walkDisplay)"
    }
}

// MARK: - Row Background (Liquid Glass / Material)

/// リスト行の背景。iOS 26 では Liquid Glass、iOS 17–25 では .ultraThinMaterial。
private struct ListingRowBackground: View {
    var body: some View {
        if #available(iOS 26, *) {
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
}

// MARK: - Row

/// 一覧の1行。OOUI: 物件オブジェクトの要約。タップで詳細、ハートでいいねトグル。
struct ListingRowView: View {
    let listing: Listing
    var onTap: () -> Void
    var onLikeTapped: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(listing.name)
                        .font(ListingObjectStyle.title)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    HStack(spacing: 10) {
                        Label(listing.priceDisplay, systemImage: "yensign.circle")
                        Label(listing.layout ?? "—", systemImage: "rectangle.split.3x1")
                        Label(listing.areaDisplay, systemImage: "square.dashed")
                        Label(listing.walkDisplay, systemImage: "figure.walk")
                    }
                    .font(ListingObjectStyle.subtitle)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if listing.isShinchiku {
                            Label(listing.deliveryDateDisplay, systemImage: "calendar")
                        } else {
                            Label(listing.builtAgeDisplay, systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            Label(listing.floorDisplay, systemImage: "building")
                            Label(listing.ownershipShort, systemImage: "doc.text")
                        }
                        Label(listing.totalUnitsDisplay, systemImage: "person.2")
                    }
                    .font(ListingObjectStyle.caption)
                    .foregroundStyle(.tertiary)
                    if let line = listing.stationLine, !line.isEmpty {
                        Text(line)
                            .font(ListingObjectStyle.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let memo = listing.memo, !memo.isEmpty {
                        Text(memo)
                            .font(ListingObjectStyle.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            Button(action: onLikeTapped) {
                Image(systemName: listing.isLiked ? "heart.fill" : "heart")
                    .font(.body)
                    .foregroundStyle(listing.isLiked ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(listing.isLiked ? "いいねを解除" : "いいねする")
        }
    }
}


#Preview {
    ListingListView()
        .environment(ListingStore.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
