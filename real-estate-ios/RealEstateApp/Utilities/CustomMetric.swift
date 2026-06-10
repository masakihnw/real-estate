import Foundation

/// ユーザー定義の合成指標（My指標）。
///
/// 「資産性重視」「通勤重視」などユーザーごとに異なる優先軸を、
/// 既存スコアの重み付き平均として1つの値に合成する。
/// 一覧のソート「My指標順」で使用。重みは設定画面で調整し UserDefaults に永続化。
struct CustomMetric: Codable, Equatable {
    /// 各コンポーネントの重み（0.0〜1.0）。合計が1でなくてもよい（利用可能な
    /// コンポーネントの重みで再正規化されるため）。
    var weightPriceFairness: Double = 0.3
    var weightResaleLiquidity: Double = 0.3
    var weightListingScore: Double = 0.2
    var weightWalkConvenience: Double = 0.1
    var weightAIRecommendation: Double = 0.1

    static let storageKey = "customMetric.weights"

    /// 徒歩分数を 0-100 スコアに変換する基準（この分数で0点）
    static let walkMinWorst = 20.0

    /// 物件の合成スコア（0-100）。利用可能なコンポーネントがなければ nil。
    /// 欠損コンポーネントは除外し、残りの重みで再正規化する
    /// （データの揃っていない物件が不当に低くならないように）。
    func score(for listing: Listing) -> Double? {
        var weightedSum = 0.0
        var totalWeight = 0.0

        if let fairness = listing.priceFairnessScore, weightPriceFairness > 0 {
            weightedSum += Double(fairness) * weightPriceFairness
            totalWeight += weightPriceFairness
        }
        if let liquidity = listing.resaleLiquidityScore, weightResaleLiquidity > 0 {
            weightedSum += Double(liquidity) * weightResaleLiquidity
            totalWeight += weightResaleLiquidity
        }
        if let score = listing.listingScore, weightListingScore > 0 {
            weightedSum += Double(score) * weightListingScore
            totalWeight += weightListingScore
        }
        if let walk = listing.walkMin, weightWalkConvenience > 0 {
            // 徒歩0分=100点、walkMinWorst分以上=0点 の線形変換
            let walkScore = max(0, 100 - Double(walk) / Self.walkMinWorst * 100)
            weightedSum += walkScore * weightWalkConvenience
            totalWeight += weightWalkConvenience
        }
        if let ai = listing.aiRecommendationScore, weightAIRecommendation > 0 {
            // 1〜5 → 0〜100
            let aiScore = Double(ai - 1) / 4.0 * 100
            weightedSum += aiScore * weightAIRecommendation
            totalWeight += weightAIRecommendation
        }

        guard totalWeight > 0 else { return nil }
        return weightedSum / totalWeight
    }

    // MARK: - 永続化

    static func load(from defaults: UserDefaults = .standard) -> CustomMetric {
        guard let data = defaults.data(forKey: storageKey),
              let metric = try? JSONDecoder().decode(CustomMetric.self, from: data) else {
            return CustomMetric()
        }
        return metric
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
