//
//  ListingFilter.swift
//  RealEstateApp
//
//  OOUI: 物件コレクションに対するフィルタ条件を表すモデル。
//  View 層（ListingListView, MapTabView）と FilterStore から参照される。
//

import Foundation

// MARK: - 権利形態フィルタ

enum OwnershipType: String, CaseIterable, Hashable {
    case ownership = "所有権"
    case leasehold = "定期借地"
}

// MARK: - 物件種別フィルタ

enum PropertyTypeFilter: String, CaseIterable, Hashable {
    case all = "すべて"
    case chuko = "中古"
    case shinchiku = "新築"
}

// MARK: - フィルタ条件

struct ListingFilter: Equatable {
    var priceMin: Int? = nil              // 万円
    var priceMax: Int? = nil              // 万円
    var includePriceUndecided: Bool = true // 新築で価格未定の物件を含むか
    var layouts: Set<String> = []         // 空 = 全て
    var wards: Set<String> = []           // 空 = 全て（区名: "江東区" 等）
    var stations: Set<String> = []        // 空 = 全て（駅名: "品川" 等）
    var walkMax: Int? = nil               // 分以内
    var areaMin: Double? = nil            // ㎡以上
    var ownershipTypes: Set<OwnershipType> = []  // 空 = 全て
    var propertyType: PropertyTypeFilter = .all   // 新築/中古/すべて

    var isActive: Bool {
        priceMin != nil || priceMax != nil || !includePriceUndecided || !layouts.isEmpty || !wards.isEmpty || !stations.isEmpty || walkMax != nil || areaMin != nil || !ownershipTypes.isEmpty || propertyType != .all
    }

    mutating func reset() {
        priceMin = nil; priceMax = nil; includePriceUndecided = true; layouts = []; wards = []; stations = []; walkMax = nil; areaMin = nil; ownershipTypes = []; propertyType = .all
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
}

// MARK: - 路線別駅名（フィルタシート・ヘルパー共通）

/// 路線別駅名データ（フィルタシート用）
struct RouteStations: Equatable {
    let routeName: String
    let stationNames: [String]   // ソート済み
}
