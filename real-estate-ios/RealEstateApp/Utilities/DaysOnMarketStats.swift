import Foundation

/// 掲載日数（Days on Market）の同セグメント比較。
///
/// 「この物件の掲載日数は同区・同間取りの中で長いのか短いのか」を示すことで、
/// 売れ残り感・売り急ぎ度の判断材料にする。
enum DaysOnMarketStats {
    /// 平均算出に必要な最小サンプル数（少数で平均を出すとノイズが大きい）
    static let minSamples = 3

    /// 同区・同間取りの掲載中物件の平均掲載日数。サンプル不足なら nil。
    static func averageDays(
        ward: String,
        layout: String?,
        excludingURL: String,
        in listings: [Listing]
    ) -> Int? {
        guard !ward.isEmpty else { return nil }
        let days = listings
            .filter {
                $0.url != excludingURL &&
                $0.wardName == ward &&
                $0.layout == layout
            }
            .compactMap(\.daysOnMarket)
        guard days.count >= minSamples else { return nil }
        return days.reduce(0, +) / days.count
    }

    /// 表示用の比較ラベル（例: "同区・同間取り平均 38日"）
    static func comparisonLabel(listingDays: Int, averageDays: Int) -> String {
        let diff = listingDays - averageDays
        if abs(diff) <= max(3, averageDays / 10) {
            return "同区・同間取り平均（\(averageDays)日）並み"
        }
        return diff > 0
            ? "同区・同間取り平均（\(averageDays)日）より\(diff)日長い"
            : "同区・同間取り平均（\(averageDays)日）より\(-diff)日短い"
    }
}
