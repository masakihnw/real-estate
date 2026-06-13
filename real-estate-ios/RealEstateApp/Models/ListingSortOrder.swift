import Foundation

/// 一覧のソート順。元は ListingListView 内のネスト enum だったが、純ロジック
/// （SortCategory.swift の代表8・グループ化）とテストを View 非依存にするため
/// top-level に昇格。ListingListView 側は `typealias SortOrder = ListingSortOrder`
/// で従来の参照（`sortOrder` / 49ケース switch / availableSortOrders）を温存する。
enum ListingSortOrder: CaseIterable, Hashable {
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
