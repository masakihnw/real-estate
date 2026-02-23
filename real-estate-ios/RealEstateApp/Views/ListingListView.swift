//
//  ListingListView.swift
//  RealEstateApp
//
//  HIG・OOUI に則った一覧。オブジェクト＝物件（Listing）を一覧し、タップで詳細へ（名詞→動詞）。
//

import SwiftUI
import SwiftData

// ListingFilter / OwnershipType は Models/ListingFilter.swift に定義

// MARK: - Building Group

/// 同一マンション内の物件をグルーピングした表示単位。
/// 一覧画面で1カード=1マンションとして表示し、展開テーブルで個々の住戸を表示する。
struct ListingGroup: Identifiable {
    let id: String
    let representative: Listing
    let units: [Listing]

    var hasMultipleUnits: Bool { units.count > 1 }
}

struct ListingListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ListingStore.self) private var store
    @Query(sort: \Listing.priceMan, order: .forward) private var listings: [Listing]
    @State private var sortOrder: SortOrder = .addedDesc
    @State private var selectedListing: Listing?
    /// OOUI: タブごとに独立したフィルタ状態を持つ（中古/新築/お気に入りで干渉しない）
    @State private var filterStore = FilterStore()
    @State private var showErrorAlert = false
    @State private var comparisonListings: [Listing] = []
    @State private var showComparison = false
    @State private var isCompareMode = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    /// フィルタ＋ソート結果のキャッシュ（body 再評価時の重計算を避ける）
    @State private var cachedFiltered: [Listing] = []

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
        case deviationDesc = "偏差値の高い順"
        case profitPctDesc = "儲かる確率の高い順"
    }

    /// タブの物件種別に応じた利用可能なソート順
    private var availableSortOrders: [SortOrder] {
        let common: [SortOrder] = [.addedDesc, .priceAsc, .priceDesc, .walkAsc, .areaDesc]
        switch propertyTypeFilter {
        case "chuko":
            return common + [.deviationDesc]
        case "shinchiku":
            return common + [.profitPctDesc]
        default:
            // お気に入りタブ等：両方表示
            return common + [.deviationDesc, .profitPctDesc]
        }
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

    /// フィルタ＋ソートを適用した結果（ロジックの実体）
    private func computeFilteredAndSorted() -> [Listing] {
        var list = filterStore.filter.apply(to: baseList)

        // テキスト検索（物件名のみ・View専用）
        if isSearchActive {
            let query = searchText.lowercased().trimmingCharacters(in: .whitespaces)
            list = list.filter { listing in
                listing.name.lowercased().contains(query)
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
        case .deviationDesc:
            list.sort {
                let d0 = $0.averageDeviation ?? 0, d1 = $1.averageDeviation ?? 0
                return d0 != d1 ? d0 > d1 : $0.name < $1.name
            }
        case .profitPctDesc:
            list.sort {
                let p0 = $0.ssProfitPct ?? 0, p1 = $1.ssProfitPct ?? 0
                return p0 != p1 ? p0 > p1 : $0.name < $1.name
            }
        }
        return list
    }

    /// キャッシュを再計算（onChange / onAppear から呼ぶ）
    private func recomputeFiltered() {
        cachedFiltered = computeFilteredAndSorted()
    }

    /// 表示用フィルタ＋ソート結果（キャッシュ。検索・ソート・フィルタ変更時のみ再計算）
    private var filteredAndSorted: [Listing] {
        cachedFiltered
    }

    /// マンション単位でグルーピングした表示用リスト。
    /// 同一 buildingGroupKey を持つ物件を1グループにまとめ、代表物件のカードで表示する。
    /// cachedFiltered のソート順を維持し、最初に出現した物件を代表とする。
    private var groupedListings: [ListingGroup] {
        let grouped = Dictionary(grouping: cachedFiltered) { $0.buildingGroupKey }
        var seen = Set<String>()
        var orderedKeys: [String] = []
        for listing in cachedFiltered {
            let key = listing.buildingGroupKey
            if seen.insert(key).inserted {
                orderedKeys.append(key)
            }
        }
        return orderedKeys.compactMap { key in
            guard let units = grouped[key], let first = units.first else { return nil }
            return ListingGroup(id: key, representative: first, units: units)
        }
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var navTitle: String {
        if favoritesOnly { return "お気に入り" }
        switch propertyTypeFilter {
        case "shinchiku": return "新築マンション"
        case "chuko": return "中古マンション"
        default: return "物件一覧"
        }
    }

    /// お気に入り物件を CSV 形式でエクスポートする
    private func exportFavoritesCSV() -> String {
        let header = "物件名,価格,住所,最寄駅,間取り,面積,築年,URL"
        let rows = filteredAndSorted.map { listing in
            let fields = [
                listing.name,
                listing.priceDisplay,
                listing.bestAddress ?? "",
                listing.primaryStationDisplay,
                listing.layout ?? "",
                listing.areaDisplay,
                listing.builtAgeDisplay,
                listing.url
            ].map { field in
                // CSV エスケープ: ダブルクォートを含む場合はエスケープ
                let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            return fields.joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    /// 一覧内に存在する間取りの一意リスト（フィルタシートの選択肢用）
    private var availableLayouts: [String] {
        ListingFilter.availableLayouts(from: baseList)
    }

    /// 一覧内に存在する区名のセット（フィルタシートの選択肢用）
    private var availableWards: Set<String> {
        ListingFilter.availableWards(from: baseList)
    }

    /// 路線別駅名リスト（フィルタシートの選択肢用）
    private var availableRouteStations: [RouteStations] {
        ListingFilter.availableRouteStations(from: baseList)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Group {
                if baseList.isEmpty && !store.isRefreshing {
                    emptyState
                    } else if favoritesOnly && delistFilter != .all && filteredAndSorted.isEmpty && !baseList.isEmpty {
                        delistFilterEmptyState
                    } else if filteredAndSorted.isEmpty && filterStore.filter.isActive {
                        filterEmptyState
                    } else {
                        listContent
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    // HTML準拠: 常時表示グレーピル型検索バー
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("物件名で検索", text: $searchText)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .submitLabel(.done)
                            .onSubmit { isSearchFocused = false }
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .navigationTitle(navTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 12) {
                            Button {
                                if isCompareMode {
                                    if comparisonListings.count >= 2 {
                                        showComparison = true
                                    } else {
                                        isCompareMode = false
                                        comparisonListings = []
                                    }
                                } else {
                                    comparisonListings = []
                                    isCompareMode = true
                                }
                            } label: {
                                Image(systemName: isCompareMode ? "checkmark.square.fill" : "square")
                                    .font(.title3)
                                    .symbolRenderingMode(.hierarchical)
                                    .overlay(alignment: .topTrailing) {
                                        if isCompareMode && comparisonListings.count > 0 {
                                            Text("\(comparisonListings.count)")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                                .frame(width: 16, height: 16)
                                                .background(Color.red)
                                                .clipShape(Circle())
                                                .offset(x: 8, y: -8)
                                        }
                                    }
                            }
                            .accessibilityLabel(isCompareMode ? "比較モード ON、\(comparisonListings.count)件選択中" : "比較モード")
                            if favoritesOnly && !filteredAndSorted.isEmpty {
                                ShareLink(
                                    item: exportFavoritesCSV(),
                                    subject: Text("お気に入り物件リスト"),
                                    preview: SharePreview("お気に入り物件リスト.csv")
                                ) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .accessibilityLabel("エクスポート")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if isCompareMode {
                            Button {
                                showComparison = true
                            } label: {
                                Text("比較する")
                                    .fontWeight(.semibold)
                            }
                            .disabled(comparisonListings.count < 2)
                        } else if store.lastError != nil {
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
                // フィルタ・並び替えボタン（右下・地図画面と同じ配置）
                if !baseList.isEmpty {
                    filterSortOverlayButtons
                }
            }
            // 手動更新は無効化。データ更新はフォアグラウンド復帰時の自動更新（15分間隔）のみ。
            .sheet(item: $selectedListing) { listing in
                let index = cachedFiltered.firstIndex(where: { $0.url == listing.url }) ?? 0
                ListingDetailPagerView(listings: cachedFiltered, initialIndex: index)
            }
            .sheet(isPresented: $showComparison, onDismiss: {
                isCompareMode = false
                comparisonListings = []
            }) {
                ComparisonView(listings: comparisonListings)
            }
            .fullScreenCover(isPresented: Binding(get: { filterStore.showFilterSheet }, set: { filterStore.showFilterSheet = $0 })) {
                ListingFilterSheet(filter: Binding(get: { filterStore.filter }, set: { filterStore.filter = $0 }), availableLayouts: availableLayouts, availableWards: availableWards, availableRouteStations: availableRouteStations, filteredCount: filteredAndSorted.count, showPriceUndecidedToggle: propertyTypeFilter == "shinchiku")
            }
            .alert("データ取得エラー", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(store.lastError ?? "不明なエラーが発生しました。")
            }
            .onAppear { recomputeFiltered() }
            .onChange(of: searchText) { _, _ in recomputeFiltered() }
            .onChange(of: sortOrder) { _, _ in recomputeFiltered() }
            .onChange(of: filterStore.filter) { _, _ in recomputeFiltered() }
            .onChange(of: delistFilter) { _, _ in recomputeFiltered() }
            .onChange(of: baseList.count) { _, _ in recomputeFiltered() }
        }
    }

    /// 右下のフィルタ・並び替えオーバーレイ（地図画面の現在地ボタンと同様のスタイル）
    @ViewBuilder
    private var filterSortOverlayButtons: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Menu {
                ForEach(availableSortOrders, id: \.self) { order in
                    Button {
                        withAnimation { sortOrder = order }
                    } label: {
                        if order == sortOrder {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(.systemBackground).opacity(0.9)))
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            }
            .accessibilityLabel("並び順")

            Button {
                filterStore.showFilterSheet = true
            } label: {
                Image(systemName: filterStore.filter.isActive
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.body)
                    .foregroundStyle(filterStore.filter.isActive ? .white : Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(filterStore.filter.isActive ? Color.accentColor : Color(.systemBackground).opacity(0.9))
                    )
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            }
            .accessibilityLabel("フィルタ")
        }
        .padding(.trailing, 12)
        .padding(.bottom, 20)
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
                    : "データは自動的に更新されます。\nうまく表示されない場合は下のボタンをお試しください。"
            )
        } actions: {
            if !favoritesOnly {
                Button {
                    Task {
                        store.clearETags()
                        await store.refresh(modelContext: modelContext)
                    }
                } label: {
                    Label("データを取得", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(store.isRefreshing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !favoritesOnly && store.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("更新中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: store.isRefreshing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var filterEmptyState: some View {
        ContentUnavailableView {
            Label("条件に一致する物件がありません", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("フィルタ条件を変更するか、リセットしてください。")
        } actions: {
            Button("フィルタをリセット") {
                filterStore.filter.reset()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var delistFilterEmptyState: some View {
        ContentUnavailableView {
            Label("該当する物件がありません", systemImage: "tray")
        } description: {
            Text("選択中の掲載状態に一致する物件がありません。\nフィルタを「すべて」に切り替えてください。")
        } actions: {
            Button("すべて表示") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    delistFilter = .all
                }
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
                                .font(.caption2.weight(.semibold))
                        }
                        Text(chip.rawValue)
                            .font(.footnote.weight(isSelected ? .semibold : .regular))
                        Text("\(count)")
                            .font(.caption2.weight(.medium))
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
                    if filterStore.filter.isActive {
                        Text("\(filteredAndSorted.count)/\(baseList.count)件")
                            .font(ListingObjectStyle.subtitle)
                            .foregroundStyle(.primary)
                        Button("リセット") { filterStore.filter.reset() }
                            .font(ListingObjectStyle.caption)
                    }
                    Spacer()
                    if let at = store.lastFetchedAt {
                        Text("更新: \(at.formatted(.dateTime.hour().minute()))")
                            .font(ListingObjectStyle.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(groupedListings) { group in
                let listing = group.representative
                HStack(spacing: 0) {
                    // 比較モード時のみカード左端にチェックボックスを表示
                    if isCompareMode {
                        let isSelected = comparisonListings.contains(where: { $0.url == listing.url })
                        Button {
                            if let idx = comparisonListings.firstIndex(where: { $0.url == listing.url }) {
                                comparisonListings.remove(at: idx)
                            } else if comparisonListings.count < 4 {
                                comparisonListings.append(listing)
                            }
                        } label: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    ListingRowView(
                        listing: listing,
                        siblings: group.units,
                        onTap: {
                            if isCompareMode {
                                if let idx = comparisonListings.firstIndex(where: { $0.url == listing.url }) {
                                    comparisonListings.remove(at: idx)
                                } else if comparisonListings.count < 4 {
                                    comparisonListings.append(listing)
                                }
                            } else {
                                selectedListing = listing
                            }
                        },
                        onUnitTap: { unit in
                            selectedListing = unit
                        },
                        onLikeTapped: {
                            listing.isLiked.toggle()
                            SaveErrorHandler.shared.save(modelContext, source: "ListingList")
                            FirebaseSyncService.shared.pushLikeState(for: listing)
                        }
                    )
                }
                .animation(.easeInOut(duration: 0.25), value: isCompareMode)
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
                .accessibilityHint(isCompareMode ? "タップで比較に追加・解除" : "タップで詳細。ハートでいいね")
                // HIG: Swipe Action でクイック操作を提供（比較モード時は無効）
                .swipeActions(edge: .trailing) {
                    if !isCompareMode {
                        Button {
                            listing.isLiked.toggle()
                            SaveErrorHandler.shared.save(modelContext, source: "ListingList")
                            FirebaseSyncService.shared.pushLikeState(for: listing)
                        } label: {
                            Label(
                                listing.isLiked ? "いいね解除" : "いいね",
                                systemImage: listing.isLiked ? "heart.slash" : "heart"
                            )
                        }
                        .tint(listing.isLiked ? .gray : .red)
                    }
                }
                .swipeActions(edge: .leading) {
                    if !isCompareMode {
                        Button {
                            selectedListing = listing
                        } label: {
                            Label("詳細", systemImage: "info.circle")
                        }
                        .tint(.accentColor)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .animation(.default, value: sortOrder)
        // OOUI: 比較モード時にガイダンスバナーを表示
        .safeAreaInset(edge: .top) {
            if isCompareMode {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.subheadline)
                    Text("比較する物件を選択（\(comparisonListings.count)/4件）")
                        .font(.subheadline)
                    Spacer()
                    Button("キャンセル") {
                        isCompareMode = false
                        comparisonListings = []
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("更新中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: store.isRefreshing)
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
/// siblings が2件以上の場合、展開トグルと住戸テーブルを表示する。
struct ListingRowView: View {
    let listing: Listing
    /// 同一マンション内の全住戸（代表を含む）。2件以上で展開UIを表示。
    var siblings: [Listing] = []
    var onTap: () -> Void
    /// 展開テーブル内の住戸行タップ時のコールバック
    var onUnitTap: ((Listing) -> Void)? = nil
    var onLikeTapped: () -> Void

    @State private var isExpanded = false

    private var hasExpandableUnits: Bool { siblings.count > 1 }

    /// 表示用の売出戸数（グループ住戸数 or 旧 duplicateCount のいずれか大きい方）
    private var displayUnitCount: Int {
        hasExpandableUnits ? siblings.count : listing.duplicateCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // メインカードコンテンツ
            Button(action: onTap) {
                cardContent
            }
            .buttonStyle(.plain)

            // 展開セクション（同一マンション内に2件以上の住戸がある場合）
            if hasExpandableUnits {
                expandableSection
            }
        }
    }

    // MARK: - Card Content

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 10) {
            // サムネイル画像（外観写真を優先・余白自動トリミング）
            if let thumbURL = listing.thumbnailURL {
                TrimmedAsyncImage(url: thumbURL, width: 100)
            }

            VStack(alignment: .leading, spacing: 4) {
                // 1行目: 物件名 + New + 📷 + 💬 + ♥
                HStack(alignment: .center, spacing: 6) {
                    Text(listing.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(listing.isDelisted ? .secondary : .primary)

                    if listing.isNew {
                        Text("New")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Spacer(minLength: 0)

                    if listing.hasPhotos {
                        HStack(spacing: 2) {
                            Image(systemName: "camera.fill")
                                .font(.caption2)
                            Text("\(listing.photoCount)")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }

                    if listing.hasComments {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.fill")
                                .font(.caption2)
                            Text("\(listing.commentCount)")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }

                    Button(action: onLikeTapped) {
                        Image(systemName: listing.isLiked ? "heart.fill" : "heart")
                            .font(.subheadline)
                            .foregroundStyle(listing.isLiked ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(listing.isLiked ? "いいねを解除" : "いいねする")
                }

                // 2行目: 所有権/定借 + 価格 + 騰落率/儲かる確率 + [掲載終了]
                HStack(alignment: .center, spacing: 6) {
                    OwnershipBadge(listing: listing, size: .small)

                    Text(listing.priceDisplayCompact)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(listing.isShinchiku ? DesignSystem.shinchikuPriceColor : Color.accentColor)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if listing.isShinchiku {
                        if let pct = listing.ssProfitPct {
                            Text("儲かる \(pct)%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    } else if let rate = listing.ssAppreciationRate {
                        let sign = rate >= 0 ? "↑" : "↓"
                        let color: Color = rate >= 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor
                        Text("\(sign)\(Int(abs(rate)))%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if !listing.isShinchiku, let avg = listing.averageDeviation {
                        DeviationBadge(value: avg)
                    }

                    // 複数戸売出バッジ（展開UIがある場合はトグルに表示するため非表示）
                    if !hasExpandableUnits, let dupText = listing.duplicateCountDisplay {
                        Text(dupText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if listing.isDelisted {
                        Text("掲載終了")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                // 3行目: 間取り・面積・築年/入居・階・向き・戸数
                HStack(spacing: 4) {
                    Text(listing.layout ?? "—")
                    Text(listing.areaDisplay)
                    if listing.isShinchiku {
                        Text(listing.deliveryDateDisplay)
                        if listing.floorTotalDisplay != "—" {
                            Text(listing.floorTotalDisplay)
                        }
                        Text(listing.totalUnitsDisplay)
                    } else {
                        Text(listing.builtAgeDisplay)
                        if !listing.floorDisplay.isEmpty {
                            Text(listing.floorDisplay)
                        }
                        if let dir = listing.direction, !dir.isEmpty {
                            Text(dir)
                        }
                        Text(listing.totalUnitsDisplay)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                // 4行目: 路線・駅
                if let line = listing.displayStationLine, !line.isEmpty {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // ハザード＋通勤バッジ
                if listing.hasHazardRisk || listing.hasCommuteInfo {
                    BadgeRow(listing: listing)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(listing.isDelisted ? 0.75 : 1.0)
    }

    // MARK: - Expandable Section

    @ViewBuilder
    private var expandableSection: some View {
        Divider()
            .padding(.top, 2)

        // 展開トグル: 「N戸売出中 ▼」
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.2")
                    .font(.caption2)
                Text("\(siblings.count)戸売出中")
                    .font(.caption2.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(.purple)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // 住戸テーブル
        if isExpanded {
            unitTable
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var unitTable: some View {
        VStack(spacing: 0) {
            // ヘッダー行
            HStack(spacing: 0) {
                Text("間取り")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("面積")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("価格")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("階")
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)

            // 各住戸行
            ForEach(siblings, id: \.url) { unit in
                Button {
                    onUnitTap?(unit)
                } label: {
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 0) {
                            Text(unit.layout ?? "—")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(unit.areaDisplay)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(unit.priceDisplayCompact)
                                .foregroundStyle(unit.isShinchiku ? DesignSystem.shinchikuPriceColor : Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 2) {
                                Text(unit.floorDisplay.isEmpty ? "—" : unit.floorDisplay)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 80, alignment: .trailing)
                        }
                        .font(.caption)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 4)
    }
}

/// 一覧カード内のバッジ行（ハザード＋通勤時間）
/// 1行に収まる場合はまとめて表示、収まらない場合はハザード行＋通勤時間行に分ける
private struct BadgeRow: View {
    let listing: Listing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // 1行で収まる場合
            HStack(spacing: 4) {
                hazardBadges
                commuteBadges
            }
            // 改行が必要な場合：ハザード行＋通勤時間行
            VStack(alignment: .leading, spacing: 3) {
                if listing.hasHazardRisk {
                    HStack(spacing: 4) { hazardBadges }
                }
                if listing.hasCommuteInfo {
                    HStack(spacing: 8) { commuteBadges }
                }
            }
        }
    }

    @ViewBuilder
    private var hazardBadges: some View {
        if listing.hasHazardRisk {
            let labels = listing.parsedHazardData.activeLabels
            ForEach(Array(labels.enumerated()), id: \.element.label) { _, item in
                HStack(spacing: 2) {
                    Image(systemName: item.icon)
                        .font(.caption2)
                    Text(item.label)
                        .font(.caption2.weight(.medium))
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

    @ViewBuilder
    private var commuteBadges: some View {
        if let pgMin = listing.commutePlaygroundDisplay {
            HStack(spacing: 4) {
                Image("logo-playground")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 12)
                Text(pgMin)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(DesignSystem.commutePGColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DesignSystem.commutePGColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        if let m3Min = listing.commuteM3CareerDisplay {
            HStack(spacing: 4) {
                Image("logo-m3career")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 12)
                Text(m3Min)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(DesignSystem.commuteM3Color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DesignSystem.commuteM3Color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}


// MARK: - Ownership Badge

/// 所有権/定借を色付きアイコン＋テキストで一発判別可能なバッジ
/// - 所有権: 青シールド + 「所有権」
/// - 定借: オレンジ時計 + 「定借」
/// - 不明/データなし: 非表示
struct OwnershipBadge: View {
    let listing: Listing

    enum BadgeSize { case small, large }
    var size: BadgeSize = .small

    var body: some View {
        let type = listing.ownershipType
        if type != .unknown {
            HStack(spacing: 2) {
                Image(systemName: type == .owned ? "shield.checkered" : "clock.arrow.circlepath")
                    .font(size == .small ? .system(size: 8, weight: .bold) : .system(size: 10, weight: .bold))
                Text(type == .owned ? "所有権" : "定借")
                    .font(size == .small ? .system(size: 9, weight: .semibold) : .system(size: 11, weight: .semibold))
            }
            .foregroundStyle(type == .owned ? Color.accentColor : Color.orange)
            .padding(.horizontal, size == .small ? 5 : 7)
            .padding(.vertical, 2)
            .background((type == .owned ? Color.accentColor : Color.orange).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: size == .small ? 4 : 5))
        }
    }
}


// MARK: - Deviation Badge

/// 平均偏差値バッジ。50を基準に色分け（高い=青系、低い=グレー系）。
struct DeviationBadge: View {
    let value: Double

    private var color: Color {
        if value >= 60 { return .blue }
        if value >= 55 { return .cyan }
        if value >= 50 { return .teal }
        if value >= 45 { return .orange }
        return .gray
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 7, weight: .bold))
            Text(String(format: "%.1f", value))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}


#Preview {
    ListingListView()
        .environment(ListingStore.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
