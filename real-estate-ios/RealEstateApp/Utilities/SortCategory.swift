import Foundation

/// ソート項目のグループ（詳細ソートのセクション分け）。
enum SortCategory: String, CaseIterable, Hashable {
    case basic = "基本"
    case location = "立地"
    case money = "お金"
    case asset = "資産性"
    case ai = "AI"

    var displayName: String { rawValue }
}

extension ListingSortOrder {

    /// 1階層に出す代表8ソート（提案 §3.4）。実際に表示する際は availableSortOrders で絞る。
    static let representatives: [ListingSortOrder] = [
        .addedDesc,            // 新着順
        .priceAsc,             // 価格（安い順）
        .priceFairnessDesc,    // 価格の割安度
        .scoreDesc,            // 総合スコア
        .recommendationDesc,   // AI推奨
        .walkAsc,              // 駅近
        .areaDesc,             // 広さ
        .customMetricDesc,     // My指標
    ]

    /// 詳細ソートのカテゴリ。
    var category: SortCategory {
        switch self {
        case .addedDesc, .addedAsc,
             .priceAsc, .priceDesc,
             .areaAsc, .areaDesc,
             .builtAgeAsc, .builtAgeDesc,
             .floorPositionAsc, .floorPositionDesc,
             .floorTotalAsc, .floorTotalDesc,
             .totalUnitsAsc, .totalUnitsDesc,
             .balconyAreaAsc, .balconyAreaDesc:
            return .basic
        case .walkAsc, .walkDesc:
            return .location
        case .m2UnitPriceAsc, .m2UnitPriceDesc,
             .tsuboUnitPriceAsc, .tsuboUnitPriceDesc,
             .managementFeeAsc, .managementFeeDesc,
             .repairReserveFundAsc, .repairReserveFundDesc,
             .monthlyRunningCostAsc, .monthlyRunningCostDesc:
            return .money
        case .deviationAsc, .deviationDesc,
             .appreciationRateAsc, .appreciationRateDesc,
             .profitPctAsc, .profitPctDesc,
             .favoriteCountAsc, .favoriteCountDesc,
             .scoreAsc, .scoreDesc,
             .priceFairnessAsc, .priceFairnessDesc,
             .resaleLiquidityAsc, .resaleLiquidityDesc,
             .competingListingsAsc, .competingListingsDesc,
             .forecastChangeRateAsc, .forecastChangeRateDesc,
             .customMetricDesc:
            return .asset
        case .recommendationAsc, .recommendationDesc:
            return .ai
        }
    }

    /// 詳細ソート用: 全ソートをカテゴリ順（基本→立地→お金→資産性→AI）・宣言順に並べる。
    /// データ非依存の静的構造。`only` を渡すとその集合（例: availableSortOrders）に絞る。
    static func grouped(only available: [ListingSortOrder]? = nil) -> [(category: SortCategory, sorts: [ListingSortOrder])] {
        let allowed: Set<ListingSortOrder>? = available.map(Set.init)
        return SortCategory.allCases.compactMap { category in
            let sorts = allCases.filter {
                $0.category == category && (allowed?.contains($0) ?? true)
            }
            return sorts.isEmpty ? nil : (category, sorts)
        }
    }
}
