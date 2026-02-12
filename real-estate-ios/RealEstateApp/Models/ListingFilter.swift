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
    var walkMax: Int? = nil               // 分以内
    var areaMin: Double? = nil            // ㎡以上
    var ownershipTypes: Set<OwnershipType> = []  // 空 = 全て
    var propertyType: PropertyTypeFilter = .all   // 新築/中古/すべて

    var isActive: Bool {
        priceMin != nil || priceMax != nil || !includePriceUndecided || !layouts.isEmpty || !wards.isEmpty || walkMax != nil || areaMin != nil || !ownershipTypes.isEmpty || propertyType != .all
    }

    mutating func reset() {
        priceMin = nil; priceMax = nil; includePriceUndecided = true; layouts = []; wards = []; walkMax = nil; areaMin = nil; ownershipTypes = []; propertyType = .all
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
}
