import Foundation

/// ウォッチリスト（いいね済み or 高評価 S/A）物件の値下げ抽出ロジック。
///
/// TodayDigest・WatchlistView とユニットテストから参照する単一実装。
/// View の private computed property に直接書くとテストが実装のコピーを
/// 検証することになるため、必ずここに集約する。
enum WatchlistFilter {
    /// ウォッチ対象とみなす資産グレード
    static let highGrades: Set<String> = ["S", "A"]

    /// ウォッチ対象（いいね済み or S/A グレード）かどうか
    static func isWatchlisted(_ listing: Listing) -> Bool {
        if listing.isLiked { return true }
        if let grade = listing.assetGrade { return highGrades.contains(grade) }
        return false
    }

    /// 値下げしたウォッチ対象物件を、値下げ幅の大きい順に最大 `limit` 件返す。
    static func priceDrops(in listings: [Listing], limit: Int = 5) -> [Listing] {
        Array(
            listings
                .filter { ($0.latestPriceChange ?? 0) < 0 && isWatchlisted($0) }
                .sorted { abs($0.latestPriceChange ?? 0) > abs($1.latestPriceChange ?? 0) }
                .prefix(limit)
        )
    }
}
