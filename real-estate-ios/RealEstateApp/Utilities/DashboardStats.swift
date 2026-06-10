import Foundation

/// ダッシュボード表示用の集計結果。
///
/// 以前は 8 個の computed property がそれぞれ全物件（数百件）を走査しており、
/// body 評価のたびに「件数 × 8 パス」のコストが発生していた。
/// ここで 1 回の単一パス + 部分ソートに統合し、body 先頭で 1 度だけ構築して
/// 各セクションに渡す。
@MainActor
struct DashboardStats {
    struct WardScoreRanking: Hashable {
        let ward: String
        let avgScore: Int
        let count: Int
    }

    struct ScoreGrades {
        var s = 0
        var a = 0
        var b = 0
        var c = 0
        var d = 0
        var maxCount: Int { max(max(max(s, a), max(b, c)), max(d, 1)) }
    }

    /// 重複排除済みの新着物件（addedAt 降順）
    let newListings: [Listing]
    /// 値下げ物件（値下げ幅の大きい順）
    let priceDecreased: [Listing]
    /// 値上げ物件（値上げ幅の大きい順）
    let priceIncreased: [Listing]
    /// ウォッチリスト（いいね/S・A）の値下げ物件（最大5件）
    let watchlistDrops: [Listing]
    /// スワイプ未仕分け件数
    let pendingSwipeCount: Int
    /// スコア分布
    let scoreGrades: ScoreGrades
    /// 区別の平均スコアランキング
    let wardRankings: [WardScoreRanking]
    /// 重複候補を持つ物件数
    let dedupCount: Int
    /// AI推奨トップ物件（建物グループで重複排除、最大3件）
    let aiTopListings: [Listing]

    init(activeListings: [Listing], prefStore: BuildingPreferenceStore? = nil) {
        var recentlyAdded: [Listing] = []
        var decreased: [Listing] = []
        var increased: [Listing] = []
        var grades = ScoreGrades()
        var wardData: [String: (totalScore: Int, count: Int)] = [:]
        var dedup = 0
        var aiCandidates: [Listing] = []

        let thresholds = DesignSystem.gradeThresholds
        for listing in activeListings {
            if listing.isRecentlyAdded { recentlyAdded.append(listing) }

            let change = listing.latestPriceChange ?? 0
            if change < 0 {
                decreased.append(listing)
            } else if change > 0 {
                increased.append(listing)
            }

            if let score = listing.listingScore {
                switch thresholds.grade(for: score) {
                case "S": grades.s += 1
                case "A": grades.a += 1
                case "B": grades.b += 1
                case "C": grades.c += 1
                default: grades.d += 1
                }
                let ward = listing.wardName
                if !ward.isEmpty {
                    let existing = wardData[ward] ?? (0, 0)
                    wardData[ward] = (existing.totalScore + score, existing.count + 1)
                }
            }

            if !listing.parsedDedupCandidates.isEmpty { dedup += 1 }

            if listing.highlightBadge != nil,
               listing.investmentSummary != nil,
               (listing.aiRecommendationScore ?? 0) >= 4 {
                aiCandidates.append(listing)
            }
        }

        decreased.sort { abs($0.latestPriceChange ?? 0) > abs($1.latestPriceChange ?? 0) }
        increased.sort { abs($0.latestPriceChange ?? 0) > abs($1.latestPriceChange ?? 0) }

        newListings = DashboardView.deduplicatedNewListings(recentlyAdded, prefStore: prefStore)
        priceDecreased = decreased
        priceIncreased = increased
        // decreased は値下げのみ + ソート済みなので、その中からウォッチ対象を抽出するだけでよい
        watchlistDrops = WatchlistFilter.priceDrops(in: decreased)
        pendingSwipeCount = SwipeSessionViewModel.pendingCount(from: activeListings)
        scoreGrades = grades
        wardRankings = wardData
            .map { ward, data in
                WardScoreRanking(ward: ward, avgScore: data.totalScore / max(data.count, 1), count: data.count)
            }
            .sorted { $0.avgScore > $1.avgScore }
        dedupCount = dedup

        var seenBuildings = Set<String>()
        aiTopListings = Array(
            aiCandidates
                .sorted { ($0.listingScore ?? 0) > ($1.listingScore ?? 0) }
                .filter { seenBuildings.insert($0.buildingGroupKey).inserted }
                .prefix(3)
        )
    }
}
