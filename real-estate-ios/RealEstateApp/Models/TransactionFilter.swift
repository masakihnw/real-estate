//
//  TransactionFilter.swift
//  RealEstateApp
//
//  成約実績データに対するフィルタ条件モデル。
//  ListingFilter のサブセット + 取引固有フィルタ（取引時期）。
//

import Foundation

struct TransactionFilter: Equatable {
    var priceMin: Int? = nil              // 万円
    var priceMax: Int? = nil              // 万円
    var layouts: Set<String> = []         // 空 = 全て
    var wards: Set<String> = []           // 空 = 全て（市区町村名: "江東区" 等）
    var stations: Set<String> = []        // 空 = 全て（駅名）
    var walkMax: Int? = nil               // 推定徒歩分以内
    var areaMin: Double? = nil            // ㎡以上
    var builtYearMin: Int? = nil          // 築年（以降）
    var tradePeriods: Set<String> = []    // 空 = 全て（"2025Q2" 等）

    var isActive: Bool {
        priceMin != nil || priceMax != nil || !layouts.isEmpty ||
        !wards.isEmpty || !stations.isEmpty || walkMax != nil ||
        areaMin != nil || builtYearMin != nil || !tradePeriods.isEmpty
    }

    mutating func reset() {
        priceMin = nil; priceMax = nil; layouts = []; wards = []
        stations = []; walkMax = nil; areaMin = nil; builtYearMin = nil
        tradePeriods = []
    }

    /// フィルタ条件を [TransactionRecord] に適用して絞り込んだ結果を返す。
    func apply(to records: [TransactionRecord]) -> [TransactionRecord] {
        var list = records

        if let min = priceMin {
            list = list.filter { $0.priceMan >= min }
        }
        if let max = priceMax {
            list = list.filter { $0.priceMan <= max }
        }
        if !layouts.isEmpty {
            list = list.filter { layouts.contains($0.layout) }
        }
        if !wards.isEmpty {
            list = list.filter { wards.contains($0.ward) }
        }
        if !stations.isEmpty {
            list = list.filter { tx in
                guard let station = tx.nearestStation else { return false }
                return stations.contains(station)
            }
        }
        if let max = walkMax {
            list = list.filter { ($0.estimatedWalkMin ?? 99) <= max }
        }
        if let min = areaMin {
            list = list.filter { $0.areaM2 >= min }
        }
        if let min = builtYearMin {
            list = list.filter { $0.builtYear >= min }
        }
        if !tradePeriods.isEmpty {
            list = list.filter { tradePeriods.contains($0.tradePeriod) }
        }
        return list
    }

    // MARK: - ヘルパー

    static func availableLayouts(from records: [TransactionRecord]) -> [String] {
        Set(records.map(\.layout).filter { !$0.isEmpty }).sorted()
    }

    static func availableWards(from records: [TransactionRecord]) -> Set<String> {
        Set(records.map(\.ward))
    }

    static func availableStations(from records: [TransactionRecord]) -> [String] {
        Set(records.compactMap(\.nearestStation)).sorted()
    }

    static func availablePeriods(from records: [TransactionRecord]) -> [String] {
        Set(records.map(\.tradePeriod)).sorted()
    }
}

// MARK: - TransactionFilterStore

@Observable
final class TransactionFilterStore {
    var filter = TransactionFilter()
    var showFilterSheet = false
}
