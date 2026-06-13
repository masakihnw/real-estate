import Foundation

/// 比較表の1行（ラベル＋各物件の表示値＋差分ハイライト用の数値）。
/// View から比較行の定義を分離し、テスト可能にする（提案 §3.6）。
struct ComparisonRowData: Identifiable {
    let label: String
    let values: [String]
    /// 差分ハイライト用の数値（nil 要素は欠損）。nil の場合はハイライトしない。
    let numeric: [Double?]?
    let higherIsBetter: Bool

    var id: String { label }

    /// 最良の物件インデックス（緑）。ComparisonHighlight に委譲。
    var bestIndex: Int? {
        numeric.flatMap { ComparisonHighlight.bestIndex($0, higherIsBetter: higherIsBetter) }
    }
    /// 最劣の物件インデックス（赤）。
    var worstIndex: Int? {
        numeric.flatMap { ComparisonHighlight.worstIndex($0, higherIsBetter: higherIsBetter) }
    }

    init(_ label: String, values: [String], numeric: [Double?]? = nil, higherIsBetter: Bool = true) {
        self.label = label
        self.values = values
        self.numeric = numeric
        self.higherIsBetter = higherIsBetter
    }
}

/// 比較対象の物件群から比較行を構築する純関数。
/// 旧 ComparisonView の basicRows / optionalRows と同一定義・同一順序・同一条件を保つ。
enum ComparisonRowBuilder {
    static func rows(for listings: [Listing]) -> [ComparisonRowData] {
        var rows: [ComparisonRowData] = []

        // 投資スコア（グレード文字を prefix）
        if listings.contains(where: { $0.listingScore != nil }) {
            rows.append(ComparisonRowData(
                "投資スコア",
                values: listings.map { l in
                    let grade = l.scoreGradeLetter.map { "\($0) " } ?? ""
                    return l.listingScore.map { "\(grade)\($0)" } ?? "—"
                },
                numeric: listings.map { $0.listingScore.map(Double.init) },
                higherIsBetter: true
            ))
        }

        rows.append(ComparisonRowData("価格", values: listings.map(\.priceDisplay),
                                      numeric: listings.map { $0.priceMan.map(Double.init) }, higherIsBetter: false))
        rows.append(ComparisonRowData("面積", values: listings.map(\.areaDisplay),
                                      numeric: listings.map(\.areaM2), higherIsBetter: true))
        rows.append(ComparisonRowData("間取り", values: listings.map { $0.layout ?? "—" }))
        rows.append(ComparisonRowData("最寄駅", values: listings.map { $0.stationName ?? "—" }))
        rows.append(ComparisonRowData("徒歩", values: listings.map(\.walkDisplay),
                                      numeric: listings.map { $0.walkMin.map(Double.init) }, higherIsBetter: false))
        rows.append(ComparisonRowData("築年", values: listings.map(\.builtAgeDisplay),
                                      numeric: listings.map { $0.builtYear.map(Double.init) }, higherIsBetter: true))
        rows.append(ComparisonRowData("階数", values: listings.map { $0.floorDisplay.isEmpty ? "—" : $0.floorDisplay }))
        rows.append(ComparisonRowData("総戸数", values: listings.map(\.totalUnitsDisplay),
                                      numeric: listings.map { $0.totalUnits.map(Double.init) }, higherIsBetter: true))
        rows.append(ComparisonRowData("権利形態", values: listings.map(\.ownershipShort)))

        if listings.contains(where: { $0.ssProfitPct != nil }) {
            rows.append(ComparisonRowData("儲かる確率", values: listings.map(\.ssProfitDisplay),
                                          numeric: listings.map { $0.ssProfitPct.map(Double.init) }, higherIsBetter: true))
        }
        if listings.contains(where: { $0.ssAppreciationRate != nil }) {
            rows.append(ComparisonRowData("値上がり率",
                                          values: listings.map { $0.ssAppreciationRate.map { String(format: "%.1f%%", $0) } ?? "—" },
                                          numeric: listings.map(\.ssAppreciationRate), higherIsBetter: true))
        }
        if listings.contains(where: { $0.computedPriceJudgment != nil }) {
            rows.append(ComparisonRowData("割安判定", values: listings.map { $0.computedPriceJudgment ?? "—" }))
        }
        if listings.contains(where: { $0.hasMarketData }) {
            rows.append(ComparisonRowData("成約相場比", values: listings.map { $0.parsedMarketData?.priceRatioDisplay ?? "—" }))
            rows.append(ComparisonRowData("相場差額", values: listings.map { $0.parsedMarketData?.priceDiffDisplay ?? "—" }))
            rows.append(ComparisonRowData("エリア傾向", values: listings.map { $0.parsedMarketData?.trendDisplay ?? "—" }))
        }
        if listings.contains(where: { $0.hasPopulationData }) {
            rows.append(ComparisonRowData("エリア人口", values: listings.map { $0.parsedPopulationData?.populationDisplay ?? "—" }))
            rows.append(ComparisonRowData("人口増減", values: listings.map { $0.parsedPopulationData?.popChange1yrDisplay ?? "—" }))
        }

        return rows
    }
}
