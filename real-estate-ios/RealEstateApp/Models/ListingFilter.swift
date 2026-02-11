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

// MARK: - フィルタ条件

struct ListingFilter: Equatable {
    var priceMin: Int? = nil              // 万円
    var priceMax: Int? = nil              // 万円
    var layouts: Set<String> = []         // 空 = 全て
    var wards: Set<String> = []           // 空 = 全て（区名: "江東区" 等）
    var walkMax: Int? = nil               // 分以内
    var areaMin: Double? = nil            // ㎡以上
    var ownershipTypes: Set<OwnershipType> = []  // 空 = 全て
    var stations: Set<String> = []        // 空 = 全て（駅名: "目白" 等）

    var isActive: Bool {
        priceMin != nil || priceMax != nil || !layouts.isEmpty || !wards.isEmpty || walkMax != nil || areaMin != nil || !ownershipTypes.isEmpty || !stations.isEmpty
    }

    mutating func reset() {
        priceMin = nil; priceMax = nil; layouts = []; wards = []; walkMax = nil; areaMin = nil; ownershipTypes = []; stations = []
    }

    /// 住所から区名を抽出（例: "東京都江東区豊洲5丁目" → "江東区"）
    static func extractWard(from address: String?) -> String? {
        guard let addr = address else { return nil }
        if let range = addr.range(of: #"[^\d]+[区市]"#, options: .regularExpression) {
            let matched = addr[range]
            // "東京都江東区" → "江東区" のように最後の区/市名を取り出す
            if let kuRange = matched.range(of: #"[\p{Han}]+[区市]$"#, options: .regularExpression) {
                return String(matched[kuRange])
            }
        }
        return nil
    }
}
