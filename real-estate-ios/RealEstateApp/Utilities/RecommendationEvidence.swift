import Foundation

/// AI推奨フラグの「判断の根拠」を実データから組み立てる。
///
/// AI が出力するフラグ（例: "駅近◎" "価格割安"）は短いタグのみで、
/// どのデータに基づくかが不透明だった。フラグのカテゴリを判定し、
/// 物件の実データ（徒歩分数・相場比・築年など）を根拠として表示する。
/// AI の判断自体を再現するものではなく、関連する一次データの提示に徹する。
enum RecommendationEvidence {

    /// フラグに対応する根拠テキスト。対応データがなければ nil（根拠行を出さない）。
    static func evidence(for flag: String, listing: Listing) -> String? {
        // 駅・立地系
        if flag.contains("駅") || flag.contains("立地") || flag.contains("アクセス") {
            if let walk = listing.walkMin {
                let station = listing.stationName ?? "最寄駅"
                return "「\(station)」徒歩\(walk)分"
            }
            return nil
        }
        // 価格・割安系
        if flag.contains("価格") || flag.contains("割安") || flag.contains("割高") || flag.contains("相場") {
            var parts: [String] = []
            if let ratio = listing.parsedMarketData?.priceRatioDisplay, ratio != "—" {
                parts.append("成約相場比 \(ratio)")
            }
            if let fairness = listing.priceFairnessScore {
                parts.append("価格妥当性スコア \(fairness)/100")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " / ")
        }
        // 築年系
        if flag.contains("築") {
            if let year = listing.builtYear {
                return "\(year)年築（\(listing.builtAgeDisplay)）"
            }
            return nil
        }
        // 再販・流動性系
        if flag.contains("流動") || flag.contains("再販") || flag.contains("リセール") || flag.contains("売却") {
            if let score = listing.resaleLiquidityScore {
                var text = "再販流動性スコア \(score)/100"
                if let competing = listing.competingListingsCount, competing > 0 {
                    text += "（同建物の競合売出 \(competing)件）"
                }
                return text
            }
            return nil
        }
        // 面積・広さ系
        if flag.contains("広") || flag.contains("面積") || flag.contains("手狭") {
            if listing.areaM2 != nil {
                return "専有面積 \(listing.areaDisplay)（\(listing.layout ?? "—")）"
            }
            return nil
        }
        // 管理系
        if flag.contains("管理") {
            var parts: [String] = []
            if let fee = listing.managementFee {
                parts.append("管理費 \(fee.formatted())円/月")
            }
            if let fund = listing.repairReserveFund {
                parts.append("修繕積立金 \(fund.formatted())円/月")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " / ")
        }
        // 規模・戸数系
        if flag.contains("戸数") || flag.contains("規模") || flag.contains("タワー") {
            var parts: [String] = []
            if let units = listing.totalUnits {
                parts.append("総戸数 \(units)戸")
            }
            if let floors = listing.floorTotal {
                parts.append("\(floors)階建")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " / ")
        }
        // 値上がり・資産性系
        if flag.contains("値上がり") || flag.contains("資産") || flag.contains("含み益") {
            if let rate = listing.ssAppreciationRate {
                return String(format: "住まいサーフィン値上がり率 %.1f%%", rate)
            }
            if let score = listing.listingScore {
                return "総合スコア \(score)/100"
            }
            return nil
        }
        return nil
    }

    /// フラグと根拠のペア一覧（根拠が取れたものだけ）。
    static func evidenceList(for listing: Listing) -> [(flag: String, evidence: String)] {
        listing.parsedRecommendationFlags.compactMap { flag in
            evidence(for: flag, listing: listing).map { (flag, $0) }
        }
    }
}
