//
//  ListingFilter.swift
//  RealEstateApp
//
//  OOUI: 物件コレクションに対するフィルタ条件を表すモデル。
//  View 層（ListingListView, MapTabView）と FilterStore から参照される。
//

import Foundation

// MARK: - 権利形態フィルタ

enum OwnershipType: String, CaseIterable, Hashable, Codable {
    case ownership = "所有権"
    case leasehold = "定期借地"
}

// MARK: - 物件種別フィルタ

enum PropertyTypeFilter: String, CaseIterable, Hashable, Codable {
    case all = "すべて"
    case chuko = "中古"
    case shinchiku = "新築"
}

struct ListingNumericRange: Equatable, Codable {
    var min: Double? = nil
    var max: Double? = nil

    var isActive: Bool {
        min != nil || max != nil
    }
}

enum ListingNumericField: String, CaseIterable, Hashable, Codable, Identifiable {
    case builtAge = "築年数"
    case m2UnitPrice = "㎡単価"
    case tsuboUnitPrice = "坪単価"
    case managementFee = "管理費"
    case repairReserveFund = "修繕積立金"
    case monthlyRunningCost = "月額維持費"
    case floorPosition = "所在階"
    case floorTotal = "総階数"
    case totalUnits = "総戸数"
    case balconyArea = "バルコニー面積"
    case averageDeviation = "偏差値"
    case appreciationRate = "値上がり率"
    case profitPct = "儲かる確率"
    case favoriteCount = "お気に入り数"
    case listingScore = "総合スコア"
    case priceFairnessScore = "価格妥当性"
    case resaleLiquidityScore = "流動性"
    case competingListingsCount = "競合売出数"
    case forecastChangeRate = "予測変動率"

    var id: String { rawValue }

    var unitLabel: String {
        switch self {
        case .builtAge:
            return "年"
        case .floorPosition, .floorTotal:
            return "階"
        case .m2UnitPrice:
            return "万/㎡"
        case .tsuboUnitPrice:
            return "万/坪"
        case .managementFee, .repairReserveFund, .monthlyRunningCost:
            return "円/月"
        case .totalUnits:
            return "戸"
        case .balconyArea:
            return "㎡"
        case .appreciationRate, .profitPct, .forecastChangeRate:
            return "%"
        case .averageDeviation, .favoriteCount, .listingScore, .priceFairnessScore,
             .resaleLiquidityScore, .competingListingsCount:
            return ""
        }
    }

    var presets: [Double] {
        switch self {
        case .builtAge:
            return [0, 3, 5, 10, 15, 20, 30]
        case .m2UnitPrice:
            return [80, 100, 120, 140, 160, 180, 200]
        case .tsuboUnitPrice:
            return [200, 250, 300, 350, 400, 450, 500]
        case .managementFee, .repairReserveFund:
            return [5_000, 10_000, 15_000, 20_000, 25_000, 30_000]
        case .monthlyRunningCost:
            return [15_000, 20_000, 30_000, 40_000, 50_000, 60_000]
        case .floorPosition:
            return [1, 2, 3, 5, 10, 15, 20]
        case .floorTotal:
            return [5, 10, 15, 20, 30, 40, 50]
        case .totalUnits:
            return [20, 50, 100, 200, 300, 500, 800]
        case .balconyArea:
            return [5, 10, 15, 20, 25, 30]
        case .averageDeviation:
            return [45, 50, 55, 60, 65, 70]
        case .appreciationRate, .forecastChangeRate:
            return [-20, -10, 0, 5, 10, 20, 30]
        case .profitPct:
            return [10, 20, 30, 40, 50, 60, 70]
        case .favoriteCount:
            return [10, 20, 30, 50, 100, 200]
        case .listingScore, .priceFairnessScore, .resaleLiquidityScore:
            return [40, 50, 60, 70, 80, 90]
        case .competingListingsCount:
            return [1, 2, 3, 5, 10, 20]
        }
    }

    func value(from listing: Listing) -> Double? {
        switch self {
        case .builtAge:
            return listing.builtAgeYears.map(Double.init)
        case .m2UnitPrice:
            return listing.m2UnitPrice
        case .tsuboUnitPrice:
            return listing.tsuboUnitPrice
        case .managementFee:
            return listing.managementFee.map(Double.init)
        case .repairReserveFund:
            return listing.repairReserveFund.map(Double.init)
        case .monthlyRunningCost:
            return listing.monthlyRunningCost.map(Double.init)
        case .floorPosition:
            return listing.floorPosition.map(Double.init)
        case .floorTotal:
            return listing.floorTotal.map(Double.init)
        case .totalUnits:
            return listing.totalUnits.map(Double.init)
        case .balconyArea:
            return listing.balconyAreaM2
        case .averageDeviation:
            return listing.averageDeviation
        case .appreciationRate:
            return listing.ssAppreciationRate
        case .profitPct:
            return listing.ssProfitPct.map(Double.init)
        case .favoriteCount:
            return listing.ssFavoriteCount.map(Double.init)
        case .listingScore:
            return listing.listingScore.map(Double.init)
        case .priceFairnessScore:
            return listing.priceFairnessScore.map(Double.init)
        case .resaleLiquidityScore:
            return listing.resaleLiquidityScore.map(Double.init)
        case .competingListingsCount:
            return listing.competingListingsCount.map(Double.init)
        case .forecastChangeRate:
            return listing.ssForecastChangeRate
        }
    }

    func format(_ value: Double) -> String {
        let isIntegerLike = abs(value.rounded() - value) < 0.0001
        switch self {
        case .managementFee, .repairReserveFund, .monthlyRunningCost:
            return "\(Int(value).formatted())\(unitLabel)"
        case .m2UnitPrice, .tsuboUnitPrice, .averageDeviation, .appreciationRate, .forecastChangeRate:
            let text = isIntegerLike ? String(Int(value.rounded())) : String(format: "%.1f", value)
            return unitLabel.isEmpty ? text : "\(text)\(unitLabel)"
        default:
            let text = isIntegerLike ? String(Int(value.rounded())) : String(format: "%.1f", value)
            return unitLabel.isEmpty ? text : "\(text)\(unitLabel)"
        }
    }
}

// MARK: - フィルタ条件

struct ListingFilter: Equatable, Codable {
    var priceMin: Int? = nil              // 万円
    var priceMax: Int? = nil              // 万円
    var includePriceUndecided: Bool = true // 新築で価格未定の物件を含むか
    var tsuboUnitPriceMin: Double? = nil  // 万円/坪
    var tsuboUnitPriceMax: Double? = nil  // 万円/坪
    var layouts: Set<String> = []         // 空 = 全て
    var wards: Set<String> = []           // 空 = 全て（区名: "江東区" 等）
    var stations: Set<String> = []        // 空 = 全て（駅名: "品川" 等）
    var walkMax: Int? = nil               // 分以内
    var areaMin: Double? = nil            // ㎡以上
    var ownershipTypes: Set<OwnershipType> = []  // 空 = 全て
    var propertyType: PropertyTypeFilter = .all   // 新築/中古/すべて
    var directions: Set<String> = []      // 空 = 全て
    var numericFilters: [ListingNumericField: ListingNumericRange] = [:]

    var isActive: Bool {
        priceMin != nil || priceMax != nil || !includePriceUndecided || tsuboUnitPriceMin != nil || tsuboUnitPriceMax != nil || !layouts.isEmpty || !wards.isEmpty || !stations.isEmpty || walkMax != nil || areaMin != nil || !ownershipTypes.isEmpty || propertyType != .all || !directions.isEmpty || numericFilters.values.contains(where: \.isActive)
    }

    mutating func reset() {
        priceMin = nil; priceMax = nil; includePriceUndecided = true; tsuboUnitPriceMin = nil; tsuboUnitPriceMax = nil; layouts = []; wards = []; stations = []; walkMax = nil; areaMin = nil; ownershipTypes = []; propertyType = .all; directions = []; numericFilters = [:]
    }

    /// 住所から区名を抽出（例: "東京都江東区豊洲5丁目" → "江東区"）
    static func extractWard(from address: String?) -> String? {
        guard let addr = address else { return nil }
        // 都道府県（都/道/府/県）の直後に続く区/市名を lazy match で最短抽出
        // 例: "東京都江東区豊洲5丁目" → lookbehind で「都」の後から → "江東区"
        if let range = addr.range(of: #"(?<=[都道府県])\p{Han}+?[区市]"#, options: .regularExpression) {
            return String(addr[range])
        }
        return nil
    }

    /// フィルタ条件を [Listing] に適用して絞り込んだ結果を返す。
    /// View 側の前処理（お気に入りタブ・座標有無・掲載終了除外など）の後に呼び出す想定。
    func apply(to listings: [Listing]) -> [Listing] {
        var list = listings

        // 物件種別（新築/中古）
        switch propertyType {
        case .all: break
        case .chuko: list = list.filter { $0.propertyType == "chuko" }
        case .shinchiku: list = list.filter { $0.propertyType == "shinchiku" }
        }

        // 価格未定フィルタ（includePriceUndecided が false なら除外）
        if !includePriceUndecided {
            list = list.filter { $0.priceMan != nil }
        }

        // 価格帯（新築は priceMan〜priceMaxMan の範囲交差で判定）
        if let min = priceMin {
            list = list.filter {
                guard $0.priceMan != nil || $0.priceMaxMan != nil else { return includePriceUndecided }
                let upper = $0.priceMaxMan ?? $0.priceMan ?? 0
                return upper >= min
            }
        }
        if let max = priceMax {
            list = list.filter {
                guard $0.priceMan != nil || $0.priceMaxMan != nil else { return includePriceUndecided }
                let lower = $0.priceMan ?? 0
                return lower <= max
            }
        }

        // 坪単価
        if let min = tsuboUnitPriceMin {
            list = list.filter {
                guard let tp = $0.tsuboUnitPrice else { return false }
                return tp >= min
            }
        }
        if let max = tsuboUnitPriceMax {
            list = list.filter {
                guard let tp = $0.tsuboUnitPrice else { return false }
                return tp <= max
            }
        }

        if !layouts.isEmpty {
            list = list.filter { layouts.contains($0.layout ?? "") }
        }
        if !wards.isEmpty {
            list = list.filter { listing in
                guard let ward = Self.extractWard(from: listing.bestAddress) else { return false }
                return wards.contains(ward)
            }
        }
        if !stations.isEmpty {
            list = list.filter { listing in
                listing.parsedStations.contains { stations.contains($0.stationName) }
            }
        }
        if let max = walkMax {
            list = list.filter { ($0.walkMin ?? 99) <= max }
        }
        if let min = areaMin {
            list = list.filter { ($0.areaM2 ?? 0) >= min }
        }
        if !ownershipTypes.isEmpty {
            list = list.filter { listing in
                let o = listing.ownership ?? ""
                return ownershipTypes.contains { type in
                    switch type {
                    case .ownership: return o.contains("所有権")
                    case .leasehold: return o.contains("借地")
                    }
                }
            }
        }
        if !directions.isEmpty {
            list = list.filter { listing in
                guard let direction = listing.direction, !direction.isEmpty else { return false }
                return directions.contains(direction)
            }
        }
        for (field, range) in numericFilters where range.isActive {
            list = list.filter { listing in
                guard let value = field.value(from: listing) else { return false }
                if let min = range.min, value < min { return false }
                if let max = range.max, value > max { return false }
                return true
            }
        }
        return list
    }

    /// 一覧内に存在する間取りの一意リスト（フィルタシートの選択肢用）
    static func availableLayouts(from listings: [Listing]) -> [String] {
        let all = Set(listings.compactMap(\.layout).filter { !$0.isEmpty })
        return all.sorted()
    }

    /// 一覧内に存在する区名のセット（フィルタシートの選択肢用）
    static func availableWards(from listings: [Listing]) -> Set<String> {
        Set(listings.compactMap { extractWard(from: $0.bestAddress) })
    }

    /// 路線別駅名リスト（フィルタシートの選択肢用）
    static func availableRouteStations(from listings: [Listing]) -> [RouteStations] {
        var routeMap: [String: Set<String>] = [:]
        for listing in listings {
            for info in listing.parsedStations where !info.routeName.isEmpty {
                routeMap[info.routeName, default: []].insert(info.stationName)
            }
        }
        return routeMap.keys.sorted().map { route in
            RouteStations(routeName: route, stationNames: routeMap[route]!.sorted())
        }
    }

    static func availableDirections(from listings: [Listing]) -> [String] {
        Array(Set(listings.compactMap(\.direction).filter { !$0.isEmpty })).sorted()
    }

    static func availableNumericFields(from listings: [Listing]) -> [ListingNumericField] {
        ListingNumericField.allCases.filter { field in
            field != .tsuboUnitPrice && listings.contains { field.value(from: $0) != nil }
        }
    }
}

// MARK: - 路線別駅名（フィルタシート・ヘルパー共通）

/// 路線別駅名データ（フィルタシート用）
struct RouteStations: Equatable {
    let routeName: String
    let stationNames: [String]   // ソート済み
}
