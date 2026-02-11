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
    @State private var showErrorAlert = false

    /// お気に入りタブの掲載状態フィルタ
    enum DelistFilter: String, CaseIterable {
        case all = "すべて"
        case active = "掲載中"
        case delisted = "掲載終了"
    }
    @State private var delistFilter: DelistFilter = .all

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
            // お気に入りタブ: いいね済み全て（掲載終了含む）
            list = listings.filter(\.isLiked)
            // 掲載状態チップフィルタ
            switch delistFilter {
            case .all: break
            case .active: list = list.filter { !$0.isDelisted }
            case .delisted: list = list.filter(\.isDelisted)
            }
        } else if let pt = propertyTypeFilter {
            // 中古/新築タブ: 掲載終了を除外
            list = listings.filter { $0.propertyType == pt && !$0.isDelisted }
        } else {
            list = listings.filter { !$0.isDelisted }
        }
        return list
    }

    var filteredAndSorted: [Listing] {
        var list = baseList

        // フィルタ
        // 新築は価格帯（priceMan〜priceMaxMan）を持つため、範囲交差で判定する
        if let min = filter.priceMin {
            list = list.filter {
                let upper = $0.priceMaxMan ?? $0.priceMan ?? 0
                return upper >= min
            }
        }
        if let max = filter.priceMax {
            list = list.filter {
                let lower = $0.priceMan ?? 0
                return lower <= max
            }
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

        // ソート（同値の場合は名前で安定ソート）
        switch sortOrder {
        case .addedDesc:
            list.sort { $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt : $0.name < $1.name }
        case .priceAsc:
            list.sort {
                let p0 = $0.priceMan ?? 0, p1 = $1.priceMan ?? 0
                return p0 != p1 ? p0 < p1 : $0.name < $1.name
            }
        case .priceDesc:
            list.sort {
                let p0 = $0.priceMan ?? 0, p1 = $1.priceMan ?? 0
                return p0 != p1 ? p0 > p1 : $0.name < $1.name
            }
        case .walkAsc:
            list.sort {
                let w0 = $0.walkMin ?? 99, w1 = $1.walkMin ?? 99
                return w0 != w1 ? w0 < w1 : $0.name < $1.name
            }
        case .areaDesc:
            list.sort {
                let a0 = $0.areaM2 ?? 0, a1 = $1.areaM2 ?? 0
                return a0 != a1 ? a0 > a1 : $0.name < $1.name
            }
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
                    VStack(spacing: 0) {
                        if favoritesOnly { delistChipBar }
                        emptyState
                    }
                } else if filteredAndSorted.isEmpty && filter.isActive {
                    filterEmptyState
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
                        .disabled(store.isRefreshing)
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
                    if store.lastError != nil {
                        Button {
                            showErrorAlert = true
                        } label: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityLabel("エラーあり")
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
            .alert("データ取得エラー", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(store.lastError ?? "不明なエラーが発生しました。")
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
                    : "更新ボタンをタップして最新の物件データを取得してください。"
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var filterEmptyState: some View {
        ContentUnavailableView {
            Label("条件に一致する物件がありません", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("フィルタ条件を変更するか、リセットしてください。")
        } actions: {
            Button("フィルタをリセット") {
                filter.reset()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// お気に入りタブ用：掲載状態チップフィルタバー
    private var delistChipBar: some View {
        HStack(spacing: 8) {
            ForEach(DelistFilter.allCases, id: \.self) { chip in
                let isSelected = delistFilter == chip
                let count: Int = {
                    let liked = listings.filter(\.isLiked)
                    switch chip {
                    case .all: return liked.count
                    case .active: return liked.filter { !$0.isDelisted }.count
                    case .delisted: return liked.filter(\.isDelisted).count
                    }
                }()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        delistFilter = chip
                    }
                } label: {
                    HStack(spacing: 4) {
                        if chip == .delisted {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(chip.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .background(isSelected ? Color.accentColor : Color(.systemGray6))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chip.rawValue) \(count)件")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var listContent: some View {
        List {
            if favoritesOnly {
                Section {
                    delistChipBar
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
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

/// リスト行の背景。iOS 26 では Liquid Glass、iOS 17–25 ではセマンティックカラー。
/// ダークモードで自動的に暗いカード色に切り替わる。
private struct ListingRowBackground: View {
    var body: some View {
        if #available(iOS 26, *) {
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
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
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                // 1行目: 物件名（左）＋ 掲載終了 / いいね（右）
                HStack(alignment: .top, spacing: 8) {
                    Text(listing.name)
                        .font(ListingObjectStyle.title)
                        .lineLimit(2)
                        .foregroundStyle(listing.isDelisted ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if listing.isDelisted {
                        Text("掲載終了")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Button(action: onLikeTapped) {
                        Image(systemName: listing.isLiked ? "heart.fill" : "heart")
                            .font(.body)
                            .foregroundStyle(listing.isLiked ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(listing.isLiked ? "いいねを解除" : "いいねする")
                }

                // 2行目: 価格・間取り・面積・徒歩
                HStack(spacing: 10) {
                    Label(listing.priceDisplay, systemImage: "yensign.circle")
                    Label(listing.layout ?? "—", systemImage: "rectangle.split.3x1")
                    Label(listing.areaDisplay, systemImage: "square.dashed")
                    Label(listing.walkDisplay, systemImage: "figure.walk")
                }
                .font(ListingObjectStyle.subtitle)
                .foregroundStyle(.secondary)

                // 3行目: 築年・階・権利・戸数
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

                // 4行目: 路線・駅
                if let line = listing.stationLine, !line.isEmpty {
                    Text(line)
                        .font(ListingObjectStyle.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // ハザードバッジ
                if listing.hasHazardRisk {
                    HazardBadgeRow(listing: listing)
                }

                // メモ
                if let memo = listing.memo, !memo.isEmpty {
                    Text(memo)
                        .font(ListingObjectStyle.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

/// 一覧カード内のハザードバッジ行
private struct HazardBadgeRow: View {
    let listing: Listing

    var body: some View {
        let hazard = listing.parsedHazardData
        let labels = hazard.activeLabels
        if !labels.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    ForEach(Array(labels.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 2) {
                            Image(systemName: item.icon)
                                .font(.system(size: 9))
                            Text(item.label)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(item.severity == .danger ? Color.red : Color.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            (item.severity == .danger ? Color.red : Color.orange).opacity(0.12)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }
}


#Preview {
    ListingListView()
        .environment(ListingStore.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
