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
    @Environment(FilterTemplateStore.self) private var templateStore
    private let networkMonitor = NetworkMonitor.shared
    @Query private var listings: [Listing]
    @State private var sortOrder: SortOrder = .addedDesc
    @State private var selectedListing: Listing?
    /// OOUI: タブごとに独立したフィルタ状態を持つ（中古/新築/お気に入りで干渉しない）
    @State private var filterStore = FilterStore()
    /// 保存フィルタチップの新着マッチ件数（テンプレートID → 件数）。
    /// body 内での都度計算を避け、baseList / templates 変化時のみ再計算する
    @State private var templateBadges: [UUID: Int] = [:]
    @State private var showErrorAlert = false
    @State private var comparisonListings: [Listing] = []
    @State private var showComparison = false
    @State private var isCompareMode = false
    @State private var searchText = ""
    /// フィルタ＋ソート結果のキャッシュ（body 再評価時の重計算を避ける。1回のState更新でUI反映を最小化）
    private struct FilterCache {
        var filtered: [Listing] = []
        var grouped: [ListingGroup] = []
        var availableLayouts: [String] = []
        var availableWards: Set<String> = []
        var availableRouteStations: [RouteStations] = []
        var availableDirections: [String] = []
        var availableNumericFields: [ListingNumericField] = []
        var availableSortOrders: [SortOrder] = []
        /// available* 計算時の baseList の署名（URL 列のハッシュ）。
        /// baseList が変わらない限り available* の全件走査をスキップするために使う
        var baseSignature: Int = 0
    }
    @State private var filterCache = FilterCache()
    /// フィルタ再計算タスク（連続変更時のキャンセル用）
    @State private var filterTask: Task<Void, Never>?
    /// Preference 変更の debounce タスク（nopedKeys/likedKeys の連鎖発火を統合）
    @State private var preferenceDebounceTask: Task<Void, Never>?
    /// 初回ロード完了フラグ（スケルトン表示の切り替え用）
    @State private var isInitialLoadComplete = false
    /// Phase 5: お気に入りタブの一括いいね解除用
    @State private var editMode: EditMode = .inactive
    @State private var selectedForDeletion: Set<String> = []
    @State private var showBulkUnlikeConfirm = false
    /// マイリストタブのフィルタ（いいね掲載状態 + Like/Nope 切り替え）
    enum DelistFilter: String, CaseIterable {
        case all = "すべて"
        case active = "掲載中"
        case delisted = "掲載終了"
        case liked = "Like"
        case noped = "Nope"
    }
    @State private var delistFilter: DelistFilter = .all
    @State private var prefListings: [Listing] = []

    /// true のとき、いいね済みの物件だけ表示する（お気に入りタブ用）
    let favoritesOnly: Bool

    /// 物件種別フィルタ: nil = 全て、"chuko" = 中古のみ、"shinchiku" = 新築のみ
    let propertyTypeFilter: String?

    init(favoritesOnly: Bool = false, propertyTypeFilter: String? = nil) {
        self.favoritesOnly = favoritesOnly
        self.propertyTypeFilter = propertyTypeFilter

        if favoritesOnly {
            _listings = Query(
                filter: #Predicate<Listing> { $0.isLiked == true },
                sort: \Listing.priceMan, order: .forward
            )
        } else {
            _listings = Query(
                filter: #Predicate<Listing> { $0.propertyType == "chuko" && $0.isDelisted == false },
                sort: \Listing.priceMan, order: .forward
            )
        }
    }

    enum SortOrder: CaseIterable, Hashable {
        case addedDesc
        case addedAsc
        case priceAsc
        case priceDesc
        case walkAsc
        case walkDesc
        case areaAsc
        case areaDesc
        case builtAgeAsc
        case builtAgeDesc
        case m2UnitPriceAsc
        case m2UnitPriceDesc
        case tsuboUnitPriceAsc
        case tsuboUnitPriceDesc
        case managementFeeAsc
        case managementFeeDesc
        case repairReserveFundAsc
        case repairReserveFundDesc
        case monthlyRunningCostAsc
        case monthlyRunningCostDesc
        case floorPositionAsc
        case floorPositionDesc
        case floorTotalAsc
        case floorTotalDesc
        case totalUnitsAsc
        case totalUnitsDesc
        case balconyAreaAsc
        case balconyAreaDesc
        case deviationAsc
        case deviationDesc
        case appreciationRateAsc
        case appreciationRateDesc
        case profitPctAsc
        case profitPctDesc
        case favoriteCountAsc
        case favoriteCountDesc
        case scoreAsc
        case scoreDesc
        case priceFairnessAsc
        case priceFairnessDesc
        case resaleLiquidityAsc
        case resaleLiquidityDesc
        case competingListingsAsc
        case competingListingsDesc
        case forecastChangeRateAsc
        case forecastChangeRateDesc
        case recommendationAsc
        case recommendationDesc
        case customMetricDesc

        var label: String {
            switch self {
            case .addedDesc: return "追加日（新しい順）"
            case .addedAsc: return "追加日（古い順）"
            case .priceAsc: return "価格（安い順）"
            case .priceDesc: return "価格（高い順）"
            case .walkAsc: return "徒歩（近い順）"
            case .walkDesc: return "徒歩（遠い順）"
            case .areaAsc: return "面積（狭い順）"
            case .areaDesc: return "面積（広い順）"
            case .builtAgeAsc: return "築年数（浅い順）"
            case .builtAgeDesc: return "築年数（古い順）"
            case .m2UnitPriceAsc: return "㎡単価（安い順）"
            case .m2UnitPriceDesc: return "㎡単価（高い順）"
            case .tsuboUnitPriceAsc: return "坪単価（安い順）"
            case .tsuboUnitPriceDesc: return "坪単価（高い順）"
            case .managementFeeAsc: return "管理費（安い順）"
            case .managementFeeDesc: return "管理費（高い順）"
            case .repairReserveFundAsc: return "修繕積立金（安い順）"
            case .repairReserveFundDesc: return "修繕積立金（高い順）"
            case .monthlyRunningCostAsc: return "月額維持費（安い順）"
            case .monthlyRunningCostDesc: return "月額維持費（高い順）"
            case .floorPositionAsc: return "所在階（低い順）"
            case .floorPositionDesc: return "所在階（高い順）"
            case .floorTotalAsc: return "総階数（低い順）"
            case .floorTotalDesc: return "総階数（高い順）"
            case .totalUnitsAsc: return "総戸数（少ない順）"
            case .totalUnitsDesc: return "総戸数（多い順）"
            case .balconyAreaAsc: return "バルコニー（狭い順）"
            case .balconyAreaDesc: return "バルコニー（広い順）"
            case .deviationAsc: return "偏差値（低い順）"
            case .deviationDesc: return "偏差値（高い順）"
            case .appreciationRateAsc: return "値上がり率（低い順）"
            case .appreciationRateDesc: return "値上がり率（高い順）"
            case .profitPctAsc: return "儲かる確率（低い順）"
            case .profitPctDesc: return "儲かる確率（高い順）"
            case .favoriteCountAsc: return "お気に入り数（少ない順）"
            case .favoriteCountDesc: return "お気に入り数（多い順）"
            case .scoreAsc: return "総合スコア（低い順）"
            case .scoreDesc: return "総合スコア（高い順）"
            case .priceFairnessAsc: return "価格妥当性（低い順）"
            case .priceFairnessDesc: return "価格妥当性（高い順）"
            case .resaleLiquidityAsc: return "流動性（低い順）"
            case .resaleLiquidityDesc: return "流動性（高い順）"
            case .competingListingsAsc: return "競合売出数（少ない順）"
            case .competingListingsDesc: return "競合売出数（多い順）"
            case .forecastChangeRateAsc: return "予測変動率（低い順）"
            case .forecastChangeRateDesc: return "予測変動率（高い順）"
            case .recommendationAsc: return "AI推奨度（低い順）"
            case .recommendationDesc: return "AI推奨度（高い順）"
            case .customMetricDesc: return "My指標（高い順）"
            }
        }

        var availabilityCheck: (Listing) -> Bool {
            switch self {
            case .addedDesc, .addedAsc, .priceAsc, .priceDesc, .walkAsc, .walkDesc, .areaAsc, .areaDesc:
                return { _ in true }
            case .builtAgeAsc, .builtAgeDesc:
                return { $0.builtAgeYears != nil }
            case .m2UnitPriceAsc, .m2UnitPriceDesc:
                return { $0.m2UnitPrice != nil }
            case .tsuboUnitPriceAsc, .tsuboUnitPriceDesc:
                return { $0.tsuboUnitPrice != nil }
            case .managementFeeAsc, .managementFeeDesc:
                return { $0.managementFee != nil }
            case .repairReserveFundAsc, .repairReserveFundDesc:
                return { $0.repairReserveFund != nil }
            case .monthlyRunningCostAsc, .monthlyRunningCostDesc:
                return { $0.monthlyRunningCost != nil }
            case .floorPositionAsc, .floorPositionDesc:
                return { $0.floorPosition != nil }
            case .floorTotalAsc, .floorTotalDesc:
                return { $0.floorTotal != nil }
            case .totalUnitsAsc, .totalUnitsDesc:
                return { $0.totalUnits != nil }
            case .balconyAreaAsc, .balconyAreaDesc:
                return { $0.balconyAreaM2 != nil }
            case .deviationAsc, .deviationDesc:
                return { $0.averageDeviation != nil }
            case .appreciationRateAsc, .appreciationRateDesc:
                return { $0.ssAppreciationRate != nil }
            case .profitPctAsc, .profitPctDesc:
                return { $0.ssProfitPct != nil }
            case .favoriteCountAsc, .favoriteCountDesc:
                return { $0.ssFavoriteCount != nil }
            case .scoreAsc, .scoreDesc:
                return { $0.listingScore != nil }
            case .priceFairnessAsc, .priceFairnessDesc:
                return { $0.priceFairnessScore != nil }
            case .resaleLiquidityAsc, .resaleLiquidityDesc:
                return { $0.resaleLiquidityScore != nil }
            case .competingListingsAsc, .competingListingsDesc:
                return { $0.competingListingsCount != nil }
            case .forecastChangeRateAsc, .forecastChangeRateDesc:
                return { $0.ssForecastChangeRate != nil }
            case .recommendationAsc, .recommendationDesc:
                return { $0.aiRecommendationScore != nil }
            case .customMetricDesc:
                // いずれかのコンポーネントがあれば計算可能。
                // load() はクロージャ外で1回だけ（全件×UserDefaults読込を避ける）
                let metric = CustomMetric.load()
                return { metric.score(for: $0) != nil }
            }
        }
    }

    /// タブの物件種別に応じた利用可能なソート順（filterCache で再計算済みのもの）
    private var availableSortOrders: [SortOrder] {
        filterCache.availableSortOrders
    }

    /// @Query で DB レベルフィルタ済み。マイリストタブのチップで追加フィルタ。
    private var baseList: [Listing] {
        if favoritesOnly {
            switch delistFilter {
            case .all: return Array(listings)
            case .active: return listings.filter { !$0.isDelisted }
            case .delisted: return listings.filter(\.isDelisted)
            case .liked:
                let keys = BuildingPreferenceStore.shared.likedKeys
                return prefListings.filter { keys.contains($0.identityKey) }
            case .noped:
                let keys = BuildingPreferenceStore.shared.nopedKeys
                return prefListings.filter { keys.contains($0.identityKey) }
            }
        }
        return Array(listings)
    }

    /// フィルタ＋ソートを適用した結果（ロジックの実体）
    private func computeFilteredAndSorted() -> [Listing] {
        var list = filterStore.filter.apply(to: baseList)

        if delistFilter != .noped && delistFilter != .liked {
            let noped = BuildingPreferenceStore.shared.nopedKeys
            if !noped.isEmpty {
                list = list.filter { !noped.contains($0.identityKey) }
            }
        }

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
        case .addedAsc:
            list.sort { $0.addedAt != $1.addedAt ? $0.addedAt < $1.addedAt : $0.name < $1.name }
        case .priceAsc:
            sortByNumericValue(&list, ascending: true) { Double($0.priceMan ?? 0) }
        case .priceDesc:
            sortByNumericValue(&list, ascending: false) { Double($0.priceMan ?? 0) }
        case .walkAsc:
            sortByNumericValue(&list, ascending: true) { Double($0.walkMin ?? 99) }
        case .walkDesc:
            sortByNumericValue(&list, ascending: false) { Double($0.walkMin ?? 99) }
        case .areaAsc:
            sortByNumericValue(&list, ascending: true) { $0.areaM2 ?? 0 }
        case .areaDesc:
            sortByNumericValue(&list, ascending: false) { $0.areaM2 ?? 0 }
        case .builtAgeAsc:
            sortByNumericValue(&list, ascending: true) { $0.builtAgeYears.map(Double.init) }
        case .builtAgeDesc:
            sortByNumericValue(&list, ascending: false) { $0.builtAgeYears.map(Double.init) }
        case .m2UnitPriceAsc:
            sortByNumericValue(&list, ascending: true) { $0.m2UnitPrice }
        case .m2UnitPriceDesc:
            sortByNumericValue(&list, ascending: false) { $0.m2UnitPrice }
        case .tsuboUnitPriceAsc:
            sortByNumericValue(&list, ascending: true) { $0.tsuboUnitPrice }
        case .tsuboUnitPriceDesc:
            sortByNumericValue(&list, ascending: false) { $0.tsuboUnitPrice }
        case .managementFeeAsc:
            sortByNumericValue(&list, ascending: true) { $0.managementFee.map(Double.init) }
        case .managementFeeDesc:
            sortByNumericValue(&list, ascending: false) { $0.managementFee.map(Double.init) }
        case .repairReserveFundAsc:
            sortByNumericValue(&list, ascending: true) { $0.repairReserveFund.map(Double.init) }
        case .repairReserveFundDesc:
            sortByNumericValue(&list, ascending: false) { $0.repairReserveFund.map(Double.init) }
        case .monthlyRunningCostAsc:
            sortByNumericValue(&list, ascending: true) { $0.monthlyRunningCost.map(Double.init) }
        case .monthlyRunningCostDesc:
            sortByNumericValue(&list, ascending: false) { $0.monthlyRunningCost.map(Double.init) }
        case .floorPositionAsc:
            sortByNumericValue(&list, ascending: true) { $0.floorPosition.map(Double.init) }
        case .floorPositionDesc:
            sortByNumericValue(&list, ascending: false) { $0.floorPosition.map(Double.init) }
        case .floorTotalAsc:
            sortByNumericValue(&list, ascending: true) { $0.floorTotal.map(Double.init) }
        case .floorTotalDesc:
            sortByNumericValue(&list, ascending: false) { $0.floorTotal.map(Double.init) }
        case .totalUnitsAsc:
            sortByNumericValue(&list, ascending: true) { $0.totalUnits.map(Double.init) }
        case .totalUnitsDesc:
            sortByNumericValue(&list, ascending: false) { $0.totalUnits.map(Double.init) }
        case .balconyAreaAsc:
            sortByNumericValue(&list, ascending: true) { $0.balconyAreaM2 }
        case .balconyAreaDesc:
            sortByNumericValue(&list, ascending: false) { $0.balconyAreaM2 }
        case .deviationAsc:
            sortByNumericValue(&list, ascending: true) { $0.averageDeviation }
        case .deviationDesc:
            sortByNumericValue(&list, ascending: false) { $0.averageDeviation }
        case .appreciationRateAsc:
            sortByNumericValue(&list, ascending: true) { $0.ssAppreciationRate }
        case .appreciationRateDesc:
            sortByNumericValue(&list, ascending: false) { $0.ssAppreciationRate }
        case .profitPctAsc:
            sortByNumericValue(&list, ascending: true) { $0.ssProfitPct.map(Double.init) }
        case .profitPctDesc:
            sortByNumericValue(&list, ascending: false) { $0.ssProfitPct.map(Double.init) }
        case .favoriteCountAsc:
            sortByNumericValue(&list, ascending: true) { $0.ssFavoriteCount.map(Double.init) }
        case .favoriteCountDesc:
            sortByNumericValue(&list, ascending: false) { $0.ssFavoriteCount.map(Double.init) }
        case .scoreAsc:
            sortByNumericValue(&list, ascending: true) { $0.listingScore.map(Double.init) }
        case .scoreDesc:
            sortByNumericValue(&list, ascending: false) { $0.listingScore.map(Double.init) }
        case .priceFairnessAsc:
            sortByNumericValue(&list, ascending: true) { $0.priceFairnessScore.map(Double.init) }
        case .priceFairnessDesc:
            sortByNumericValue(&list, ascending: false) { $0.priceFairnessScore.map(Double.init) }
        case .resaleLiquidityAsc:
            sortByNumericValue(&list, ascending: true) { $0.resaleLiquidityScore.map(Double.init) }
        case .resaleLiquidityDesc:
            sortByNumericValue(&list, ascending: false) { $0.resaleLiquidityScore.map(Double.init) }
        case .competingListingsAsc:
            sortByNumericValue(&list, ascending: true) { $0.competingListingsCount.map(Double.init) }
        case .competingListingsDesc:
            sortByNumericValue(&list, ascending: false) { $0.competingListingsCount.map(Double.init) }
        case .forecastChangeRateAsc:
            sortByNumericValue(&list, ascending: true) { $0.ssForecastChangeRate }
        case .forecastChangeRateDesc:
            sortByNumericValue(&list, ascending: false) { $0.ssForecastChangeRate }
        case .recommendationAsc:
            sortByNumericValue(&list, ascending: true) { $0.aiRecommendationScore.map(Double.init) }
        case .recommendationDesc:
            sortByNumericValue(&list, ascending: false) { $0.aiRecommendationScore.map(Double.init) }
        case .customMetricDesc:
            let metric = CustomMetric.load()
            sortByNumericValue(&list, ascending: false) { metric.score(for: $0) }
        }
        return list
    }

    private func sortByNumericValue(
        _ list: inout [Listing],
        ascending: Bool,
        value: (Listing) -> Double?
    ) {
        list.sort { lhs, rhs in
            let left = value(lhs)
            let right = value(rhs)
            switch (left, right) {
            case let (lv?, rv?):
                if lv != rv {
                    return ascending ? lv < rv : lv > rv
                }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                break
            }
            return lhs.name < rhs.name
        }
    }

    /// Preference 変更時の debounce（nopedKeys/likedKeys の連鎖発火を50msで統合）
    private func schedulePreferenceRecompute() {
        preferenceDebounceTask?.cancel()
        preferenceDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            if delistFilter == .noped || delistFilter == .liked { loadPrefListings() }
            recomputeFiltered(animated: true)
        }
    }

    /// キャッシュを非同期再計算（onChange / onAppear から呼ぶ）。
    /// 連続する変更（検索入力など）では前回のタスクをキャンセルして最新のみ実行。
    /// FilterCache を1回の代入で更新し、SwiftUI の body 再評価を最小化する。
    private func recomputeFiltered(animated: Bool = false) {
        filterTask?.cancel()
        filterTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let result = computeFilteredAndSorted()
            guard !Task.isCancelled else { return }
            let grouped = Self.computeGrouped(from: result)
            guard !Task.isCancelled else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            let currentBase = baseList
            // available* 各リストは baseList のみに依存する。検索・ソート変更のたびに
            // 全件×5回の走査を繰り返さないよう、baseList が同一なら前回値を使い回す
            var hasher = Hasher()
            for listing in currentBase { hasher.combine(listing.url) }
            // 同期で既存物件の内容が in-place 更新された場合（URL不変）も
            // 選択肢が陳腐化しないよう、最終フェッチ時刻も署名に含める
            hasher.combine(ListingStore.shared.lastFetchedAt?.timeIntervalSince1970 ?? 0)
            let signature = hasher.finalize()

            let newCache: FilterCache
            if signature == filterCache.baseSignature {
                newCache = FilterCache(
                    filtered: result,
                    grouped: grouped,
                    availableLayouts: filterCache.availableLayouts,
                    availableWards: filterCache.availableWards,
                    availableRouteStations: filterCache.availableRouteStations,
                    availableDirections: filterCache.availableDirections,
                    availableNumericFields: filterCache.availableNumericFields,
                    availableSortOrders: filterCache.availableSortOrders,
                    baseSignature: signature
                )
            } else {
                newCache = FilterCache(
                    filtered: result,
                    grouped: grouped,
                    availableLayouts: ListingFilter.availableLayouts(from: currentBase),
                    availableWards: ListingFilter.availableWards(from: currentBase),
                    availableRouteStations: ListingFilter.availableRouteStations(from: currentBase),
                    availableDirections: ListingFilter.availableDirections(from: currentBase),
                    availableNumericFields: ListingFilter.availableNumericFields(from: currentBase),
                    availableSortOrders: SortOrder.allCases.filter { order in
                        currentBase.contains(where: order.availabilityCheck)
                    },
                    baseSignature: signature
                )
            }
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(.easeInOut(duration: 0.3)) {
                    filterCache = newCache
                }
            } else {
                filterCache = newCache
            }
        }
    }

    private static func computeGrouped(from filtered: [Listing]) -> [ListingGroup] {
        let grouped = Dictionary(grouping: filtered) { $0.buildingGroupKey }
        var seen = Set<String>()
        var orderedKeys: [String] = []
        for listing in filtered {
            let key = listing.buildingGroupKey
            if seen.insert(key).inserted {
                orderedKeys.append(key)
            }
        }
        return orderedKeys.compactMap { key in
            guard let units = grouped[key], let first = units.first else { return nil }
            // 棟内の代表は「現在のソート順で最初の戸」ではなく、棟内ベスト戸を選ぶ。
            // 一覧に表示する物件名・階数・価格・★はベスト戸のものになる。
            let representative = BuildingAggregator.bestRepresentative(from: units) ?? first
            return ListingGroup(id: key, representative: representative, units: units)
        }
    }

    /// 表示用フィルタ＋ソート結果（キャッシュ。検索・ソート・フィルタ変更時のみ再計算）
    private var filteredAndSorted: [Listing] {
        filterCache.filtered
    }

    private var groupedListings: [ListingGroup] {
        filterCache.grouped
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var navTitle: String {
        if favoritesOnly { return "マイリスト" }
        return "中古マンション"
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

    private var availableLayouts: [String] { filterCache.availableLayouts }
    private var availableWards: Set<String> { filterCache.availableWards }
    private var availableRouteStations: [RouteStations] { filterCache.availableRouteStations }
    private var availableDirections: [String] { filterCache.availableDirections }
    private var availableNumericFields: [ListingNumericField] { filterCache.availableNumericFields }

    var body: some View {
        NavigationStack {
            mainContent
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        mainZStack
            .fullScreenCover(item: $selectedListing) { listing in
                let index = filterCache.filtered.firstIndex(where: { $0.url == listing.url }) ?? 0
                ListingDetailPagerView(listings: filterCache.filtered, initialIndex: index)
            }
            .sheet(isPresented: $showComparison, onDismiss: {
                isCompareMode = false
                comparisonListings = []
            }) {
                ComparisonView(listings: comparisonListings)
            }
            .fullScreenCover(isPresented: Binding(get: { filterStore.showFilterSheet }, set: { filterStore.showFilterSheet = $0 })) {
                ListingFilterSheet(
                    filter: Binding(get: { filterStore.filter }, set: { filterStore.filter = $0 }),
                    availableLayouts: availableLayouts,
                    availableWards: availableWards,
                    availableRouteStations: availableRouteStations,
                    availableDirections: availableDirections,
                    availableNumericFields: availableNumericFields,
                    filteredCount: filteredAndSorted.count,
                    showPriceUndecidedToggle: false
                )
            }
            .environment(\.editMode, favoritesOnly ? $editMode : .constant(.inactive))
            .onAppear {
                recomputeFiltered()
                recomputeTemplateBadges()
                if baseList.count > 0 || !store.isRefreshing { isInitialLoadComplete = true }
            }
            .onChange(of: store.isRefreshing) { _, isRefreshing in
                if !isRefreshing { isInitialLoadComplete = true }
            }
            .onChange(of: baseList.count) { _, count in
                if count > 0 { isInitialLoadComplete = true }
                recomputeFiltered()
                recomputeTemplateBadges()
            }
            .onChange(of: searchText) { _, _ in recomputeFiltered() }
            .onChange(of: sortOrder) { _, _ in recomputeFiltered() }
            .onChange(of: filterStore.filter) { _, newFilter in
                recomputeFiltered()
                // シート等で条件が編集されテンプレートと一致しなくなったら適用中表示を解除
                if let id = filterStore.appliedTemplateID,
                   templateStore.templates.first(where: { $0.id == id })?.filter != newFilter {
                    filterStore.appliedTemplateID = nil
                }
            }
            .onChange(of: templateStore.templates) { _, _ in recomputeTemplateBadges() }
            .onChange(of: delistFilter) { _, newFilter in
                if newFilter == .liked || newFilter == .noped { loadPrefListings() }
                recomputeFiltered()
            }
            .onChange(of: BuildingPreferenceStore.shared.nopedKeys.count) { _, _ in
                schedulePreferenceRecompute()
            }
            .onChange(of: BuildingPreferenceStore.shared.likedKeys.count) { _, _ in
                schedulePreferenceRecompute()
            }
    }

    @ViewBuilder
    private var mainZStack: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if filterCache.filtered.isEmpty && !isInitialLoadComplete {
                    SkeletonLoadingView()
                } else if favoritesOnly && delistFilter != .all && (baseList.isEmpty || filteredAndSorted.isEmpty) {
                    VStack(spacing: 0) {
                        delistChipBar
                        delistFilterEmptyState
                    }
                } else if baseList.isEmpty && !store.isRefreshing {
                    emptyState
                } else if filteredAndSorted.isEmpty && filterStore.filter.isActive {
                    filterEmptyState
                } else {
                    listContent
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "物件名で検索")
            .toolbar { listToolbarContent }
            .alert("データ取得エラー", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(store.lastError ?? "不明なエラーが発生しました。")
            }
            .alert("いいね解除", isPresented: $showBulkUnlikeConfirm) {
                Button("解除", role: .destructive) {
                    for url in selectedForDeletion {
                        if let listing = filterCache.filtered.first(where: { $0.url == url }) {
                            listing.isLiked = false
                            AnnotationRouter.pushLikeState(for: listing)
                        }
                    }
                    selectedForDeletion.removeAll()
                    editMode = .inactive
                    SaveErrorHandler.shared.save(modelContext, source: "ListingList")
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("\(selectedForDeletion.count)件の物件のいいねを解除しますか？")
            }
            if !baseList.isEmpty {
                filterSortOverlayButtons
            }
        }
    }

    @ToolbarContentBuilder
    private var listToolbarContent: some ToolbarContent {
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
                if favoritesOnly {
                    NavigationLink {
                        NopedListingsView()
                    } label: {
                        Image(systemName: "hand.thumbsdown")
                    }
                    .accessibilityLabel("Nopeした物件の管理")
                }
                if favoritesOnly && !filteredAndSorted.isEmpty {
                    EditButton()
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
                            Label(order.label, systemImage: "checkmark")
                        } else {
                            Text(order.label)
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
        let isOffline = !networkMonitor.isConnected
        return ContentUnavailableView {
            Label(
                favoritesOnly ? "マイリストは空です" : "物件がありません",
                systemImage: favoritesOnly ? "heart.slash" : (isOffline ? "wifi.slash" : "building.2")
            )
        } description: {
            Text(
                favoritesOnly
                    ? "物件一覧でハート(♥)やスワイプ(★/👎)を使うとここに表示されます。"
                    : (isOffline
                        ? "インターネットに接続されていません。\nWi-Fi またはモバイルデータをご確認ください。"
                        : "データは自動的に更新されます。\nうまく表示されない場合は下のボタンをお試しください。")
            )
        } actions: {
            if !favoritesOnly && !isOffline {
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
            VStack(spacing: 8) {
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: store.isRefreshing)
                }
                if !favoritesOnly, let errMsg = store.lastError {
                    Text(errMsg)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(8)
                        .onTapGesture {
                            UIPasteboard.general.string = errMsg
                        }
                }
            }
            .padding(.bottom, 40)
        }
        .accessibilityElement(children: .combine)
    }

    private var filterEmptyState: some View {
        // テンプレート適用で0件になった時こそ解除チップが必要なため、
        // 空状態でもチップ行を表示する
        VStack(spacing: 0) {
            if !favoritesOnly && !templateStore.templates.isEmpty {
                templateChipBar
            }
            ContentUnavailableView {
                Label("条件に一致する物件がありません", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("フィルタ条件を変更するか、リセットしてください。")
            } actions: {
                Button("フィルタをリセット") {
                    filterStore.filter.reset()
                    filterStore.appliedTemplateID = nil
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - 保存フィルタチップ（さがす側）

    /// 保存フィルタを1タップで適用するチップ行。新着マッチ件数をバッジ表示する。
    private var templateChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(templateStore.templates) { template in
                    templateChip(template)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
        }
    }

    private func templateChip(_ template: FilterTemplate) -> some View {
        let isApplied = filterStore.appliedTemplateID == template.id
        let badge = templateBadges[template.id] ?? 0
        return Button {
            HapticManager.soft()
            if isApplied {
                filterStore.filter.reset()
                filterStore.appliedTemplateID = nil
            } else {
                filterStore.filter = template.filter
                filterStore.appliedTemplateID = template.id
            }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Text(template.name)
                    .font(DS.Typography.label)
                    .lineLimit(1)
                if badge > 0 {
                    Text("\(badge)")
                        .font(DS.Typography.badge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Spacing.xs + 1)
                        .padding(.vertical, 1)
                        .background(isApplied ? Color.white.opacity(DS.Opacity.overlay) : Color.accentColor, in: Capsule())
                }
            }
            .foregroundStyle(isApplied ? .white : .primary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs + 2)
            .background(
                isApplied ? Color.accentColor : Color(.secondarySystemBackground),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            badge > 0
                ? "保存フィルタ \(template.name)、新着\(badge)件\(isApplied ? "、適用中" : "")"
                : "保存フィルタ \(template.name)\(isApplied ? "、適用中" : "")"
        )
    }

    /// 新着マッチバッジを再計算する（baseList / templates 変化時のみ）
    private func recomputeTemplateBadges() {
        guard !favoritesOnly, !templateStore.templates.isEmpty else {
            templateBadges = [:]
            return
        }
        templateBadges = FilterMatchCounter.matchCounts(
            newListings: FilterMatchCounter.newListings(in: baseList),
            templates: templateStore.templates
        )
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

    /// マイリストタブ用：チップフィルタバー（いいね掲載状態 + Like/Nope）
    private var delistChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DelistFilter.allCases, id: \.self) { chip in
                    let isSelected = delistFilter == chip
                    let count: Int = {
                        switch chip {
                        case .all: return listings.filter(\.isLiked).count
                        case .active: return listings.filter { $0.isLiked && !$0.isDelisted }.count
                        case .delisted: return listings.filter { $0.isLiked && $0.isDelisted }.count
                        case .liked: return BuildingPreferenceStore.shared.likedKeys.count
                        case .noped: return BuildingPreferenceStore.shared.nopedKeys.count
                        }
                    }()
                    let chipIcon: String? = {
                        switch chip {
                        case .delisted: return "exclamationmark.triangle"
                        case .liked: return "star.fill"
                        case .noped: return "hand.thumbsdown"
                        default: return nil
                        }
                    }()
                    let chipColor: Color = {
                        switch chip {
                        case .liked: return .yellow
                        case .noped: return .orange
                        default: return Color.accentColor
                        }
                    }()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            delistFilter = chip
                            if (chip == .liked || chip == .noped) && prefListings.isEmpty {
                                loadPrefListings()
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let icon = chipIcon {
                                Image(systemName: icon)
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
                        .background(isSelected ? chipColor : Color(.systemGray6))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(chip.rawValue) \(count)件")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func loadPrefListings() {
        let allKeys = BuildingPreferenceStore.shared.likedKeys
            .union(BuildingPreferenceStore.shared.nopedKeys)
        guard !allKeys.isEmpty else {
            prefListings = []
            return
        }
        let descriptor = FetchDescriptor<Listing>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        prefListings = all.filter { allKeys.contains($0.identityKey) }
    }

    private var listContent: some View {
        List(selection: $selectedForDeletion) {
            if favoritesOnly {
                Section {
                    delistChipBar
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if !templateStore.templates.isEmpty {
                Section {
                    templateChipBar
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
            if favoritesOnly && editMode == .active {
                ForEach(filterCache.filtered, id: \.url) { listing in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(listing.nameWithFloor)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Text(listing.priceDisplayCompact)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
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
                    .tag(listing.url)
                }
            } else {
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
                        siblings: group.units.filter { !$0.isDelisted },
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
                            AnnotationRouter.pushLikeState(for: listing)
                            if listing.isLiked {
                                SpotlightIndexer.indexListing(listing)
                            } else {
                                SpotlightIndexer.deindexListing(url: listing.url)
                            }
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
                // スワイプ: 右=Like、左=Nope（比較モード時は無効）
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if !isCompareMode {
                        Button {
                            let prefStore = BuildingPreferenceStore.shared
                            Task {
                                if prefStore.isLiked(listing.identityKey) {
                                    await prefStore.removePreference(listing.identityKey)
                                } else {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    await prefStore.setPreference(listing.identityKey, preference: .like)
                                }
                            }
                        } label: {
                            Label(
                                BuildingPreferenceStore.shared.isLiked(listing.identityKey) ? "Like解除" : "Like",
                                systemImage: BuildingPreferenceStore.shared.isLiked(listing.identityKey) ? "star.slash" : "star"
                            )
                        }
                        .tint(.yellow)
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if !isCompareMode {
                        Button {
                            let prefStore = BuildingPreferenceStore.shared
                            Task {
                                if prefStore.isNoped(listing.identityKey) {
                                    await prefStore.removePreference(listing.identityKey)
                                } else {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    await prefStore.setPreference(listing.identityKey, preference: .nope)
                                }
                            }
                        } label: {
                            Label(
                                BuildingPreferenceStore.shared.isNoped(listing.identityKey) ? "Nope解除" : "Nope",
                                systemImage: BuildingPreferenceStore.shared.isNoped(listing.identityKey) ? "hand.thumbsup" : "hand.thumbsdown"
                            )
                        }
                        .tint(.orange)
                    }
                }
                .contextMenu {
                    if !isCompareMode {
                        Button {
                            listing.isLiked.toggle()
                            SaveErrorHandler.shared.save(modelContext, source: "ListingList")
                            AnnotationRouter.pushLikeState(for: listing)
                        } label: {
                            Label(listing.isLiked ? "いいね解除" : "いいね", systemImage: listing.isLiked ? "heart.slash" : "heart")
                        }
                        Button {
                            let prefStore = BuildingPreferenceStore.shared
                            Task {
                                if prefStore.isLiked(listing.identityKey) {
                                    await prefStore.removePreference(listing.identityKey)
                                } else {
                                    await prefStore.setPreference(listing.identityKey, preference: .like)
                                }
                            }
                        } label: {
                            Label(
                                BuildingPreferenceStore.shared.isLiked(listing.identityKey) ? "Like解除" : "Like",
                                systemImage: BuildingPreferenceStore.shared.isLiked(listing.identityKey) ? "star.slash" : "star"
                            )
                        }
                        Button {
                            let prefStore = BuildingPreferenceStore.shared
                            Task {
                                if prefStore.isNoped(listing.identityKey) {
                                    await prefStore.removePreference(listing.identityKey)
                                } else {
                                    await prefStore.setPreference(listing.identityKey, preference: .nope)
                                }
                            }
                        } label: {
                            Label(
                                BuildingPreferenceStore.shared.isNoped(listing.identityKey) ? "Nope解除" : "Nope",
                                systemImage: BuildingPreferenceStore.shared.isNoped(listing.identityKey) ? "hand.thumbsup" : "hand.thumbsdown"
                            )
                        }
                        if let url = URL(string: listing.url) {
                            ShareLink(item: url, subject: Text(listing.name))
                        }
                    }
                } preview: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(listing.nameWithFloor)
                            .font(.headline)
                            .lineLimit(2)
                        Text(listing.priceDisplayCompact)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                        HStack(spacing: 12) {
                            if let area = listing.areaM2 {
                                Label(String(format: "%.1f㎡", area), systemImage: "ruler")
                            }
                            if let layout = listing.layout {
                                Label(layout, systemImage: "square.grid.3x3")
                            }
                            if let walk = listing.walkMin {
                                Label("徒歩\(walk)分", systemImage: "figure.walk")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let addr = listing.bestAddress ?? listing.address {
                            Text(addr)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding()
                    .frame(width: 300)
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
            VStack(spacing: 8) {
                if favoritesOnly && editMode == .active && !selectedForDeletion.isEmpty {
                    Button(role: .destructive) {
                        showBulkUnlikeConfirm = true
                    } label: {
                        Label("\(selectedForDeletion.count)件のいいねを解除", systemImage: "heart.slash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut, value: store.isRefreshing)
                }
            }
            .padding(.bottom, 8)
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
    @State private var isAISummaryExpanded: Bool = false

    private var hasExpandableUnits: Bool { siblings.count > 1 }

    static func priceChangeDateLabel(for listing: Listing) -> String? {
        let history = listing.parsedPriceHistory
        guard history.count >= 2, let date = history.last?.parsedDate else { return nil }
        let cal = Calendar.current
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }

    private func formatYenCompact(_ yen: Int) -> String {
        if yen >= 10000 {
            return String(format: "%.1f万", Double(yen) / 10000)
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return "\(f.string(from: NSNumber(value: yen)) ?? "\(yen)")円"
    }

    /// 月額支払いの表示文字列（万円単位）
    private func monthlyPaymentDisplay(for item: Listing) -> String? {
        guard let payment = item.estimatedMonthlyPayment else { return nil }
        let suffix = item.hasFullMonthlyCost ? "" : "〜"
        return String(format: "月々 約%.1f万円%@", payment, suffix)
    }

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

            // AI評価トグルセクション
            if listing.aiRecommendationScore != nil || listing.investmentSummary != nil {
                aiSummarySection
            }

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
            VStack(spacing: 4) {
                if let thumbURL = listing.thumbnailURL {
                    TrimmedAsyncImage(url: thumbURL, width: 80)
                }

                // マルチソースバッジ（サムネ下）
                if let badge = listing.highlightBadge {
                    HighlightBadgeView(text: badge)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                // 1行目: 物件名 + スコアバッジ + ♥
                HStack(alignment: .center, spacing: 6) {
                    Text(hasExpandableUnits ? listing.name : listing.nameWithFloor)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(listing.isDelisted ? .secondary : .primary)

                    Spacer(minLength: 0)

                    if let score = listing.listingScore,
                       let grade = listing.scoreGradeLetter {
                        ScoreBadge(grade: grade, value: score)
                    }

                    if BuildingPreferenceStore.shared.isLiked(listing.identityKey) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }

                    Button(action: onLikeTapped) {
                        Image(systemName: listing.isLiked ? "heart.fill" : "heart")
                            .font(.subheadline)
                            .foregroundStyle(listing.isLiked ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(listing.isLiked ? "いいねを解除" : "いいねする")
                }

                // 2行目: バッジ行（New/別部屋 + 所有権 + 騰落率 etc）
                HStack(alignment: .center, spacing: 4) {
                    if listing.isRecentlyAdded {
                        let isNewBadge = listing.isNewBuilding || listing.isRelisted
                        Text(isNewBadge ? "New" : "別部屋")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(isNewBadge ? Color.red : Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    OwnershipBadge(listing: listing, size: .small)

                    if let rate = listing.ssAppreciationRate {
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

                    if let avg = listing.averageDeviation {
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

                Divider()

                // 3行目: 価格 + 値下げ
                HStack(alignment: .center, spacing: 6) {
                    Text(listing.priceDisplayCompact)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let change = listing.latestPriceChange, change != 0 {
                        let isDown = change < 0
                        let dateLabel = Self.priceChangeDateLabel(for: listing)
                        Text("\(isDown ? "↓" : "↑")\(abs(change))万\(dateLabel.map { " (\($0))" } ?? "")")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor).opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                // 4行目: 月々支払い
                if let monthlyText = monthlyPaymentDisplay(for: listing) {
                    Text(monthlyText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // 5行目: スペック（ドット区切り）+ ハザードチップ
                specsRow

                // 6行目: 路線・駅
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

    // MARK: - Specs Row (dot-separated)

    @ViewBuilder
    private var specsRow: some View {
        let parts: [String] = {
            var items: [String] = []
            if let layout = listing.layout { items.append(layout) }
            items.append(listing.areaDisplay)
            if let w = listing.walkMin { items.append("🚶\(w)分") }
            items.append(listing.builtAgeDisplay)
            if !listing.floorDisplay.isEmpty { items.append(listing.floorDisplay) }
            if let dir = listing.direction, !dir.isEmpty { items.append(dir) }
            return items
        }()

        Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    // MARK: - AI Summary Toggle

    @ViewBuilder
    private var aiSummarySection: some View {
        Divider()
            .padding(.top, 2)

        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isAISummaryExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text("✦")
                    .font(.caption2)
                if let score = listing.aiRecommendationScore, score >= 1, score <= 5 {
                    Text(String(repeating: "★", count: score) + String(repeating: "☆", count: 5 - score))
                        .font(.caption2)
                        .foregroundStyle(aiStarColor)
                } else {
                    Text("AI評価")
                        .font(.caption2.weight(.semibold))
                }
                Text(isAISummaryExpanded ? "" : "タップで表示")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isAISummaryExpanded ? 180 : 0))
            }
            .foregroundStyle(.purple)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isAISummaryExpanded {
            aiExpandedContent
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var aiExpandedContent: some View {
        if let conclusion = listing.aiRecommendationSummary {
            Text(conclusion)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = listing.aiRecommendationAction, !action.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 10))
                    Text(action)
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
        } else if let summary = listing.investmentSummary {
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }

    private var aiStarColor: Color {
        switch listing.aiRecommendationScore {
        case 5: return .green
        case 4: return .blue
        case 3: return .orange
        default: return .secondary
        }
    }

    // MARK: - Expandable Section

    @ViewBuilder
    private var expandableSection: some View {
        Divider()
            .padding(.top, 2)

        // 展開トグル: 「同マンションでN戸売出中 ▼」
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "building.2")
                    .font(.caption2)
                Text("同マンションで\(siblings.count)戸売出中")
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
                Text("価格")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("月々")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("階")
                    .frame(width: 60, alignment: .trailing)
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
                            VStack(alignment: .leading, spacing: 1) {
                                Text(unit.layout ?? "—")
                                Text(unit.areaDisplay)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(unit.priceDisplayCompact)
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Group {
                                if let payment = unit.estimatedMonthlyPayment {
                                    Text(String(format: "%.1f万%@", payment, unit.hasFullMonthlyCost ? "" : "〜"))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("—")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 2) {
                                Text(unit.floorDisplay.isEmpty ? "—" : unit.floorDisplay)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(width: 60, alignment: .trailing)
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
                if listing.parsedHazardData.safetyLevel >= .moderate {
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
        let hazard = listing.parsedHazardData
        let level = hazard.safetyLevel
        if level >= .moderate {
            let color = DesignSystem.hazardSafetyColor(level)
            let totalCount = hazard.activeLabels.count
            let (top, remaining) = hazard.topLabels(max: 2)

            // 集約バッジ
            HStack(spacing: 2) {
                Image(systemName: level == .elevated
                    ? "exclamationmark.octagon.fill"
                    : "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text(level == .elevated ? "要確認" : "注意")
                    .font(.caption2.weight(.bold))
                Text("\(totalCount)件")
                    .font(.caption2)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // 上位2件の具体バッジ
            ForEach(Array(top.enumerated()), id: \.element.label) { _, item in
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

            // 超過分カウント
            if remaining > 0 {
                Text("+\(remaining)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

// MARK: - スケルトンローディング

private struct SkeletonLoadingView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                skeletonRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
            }
        }
        .onAppear { isAnimating = true }
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.systemGray5))
                .frame(width: 100, height: 75)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))
                    .frame(height: 14)
                    .frame(maxWidth: .infinity)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))
                    .frame(height: 12)
                    .frame(width: 180)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))
                    .frame(height: 12)
                    .frame(width: 140)
            }
        }
        .redacted(reason: .placeholder)
        .shimmering()
    }
}

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .overlay(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.4), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .rotationEffect(.degrees(30))
                    .offset(x: phase)
                    .mask(content)
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        phase = geometry.size.width
                    }
                }
        }
    }
}

extension View {
    fileprivate func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}


#Preview {
    ListingListView()
        .environment(ListingStore.shared)
        .environment(FilterTemplateStore())
        .modelContainer(for: Listing.self, inMemory: true)
}
