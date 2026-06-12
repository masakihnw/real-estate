import Foundation

/// 同一建物で複数戸が売り出されている場合に、一覧の代表行（ListingGroup.representative）として
/// どの戸を見せるかを決めるロジック。
///
/// 一覧は既に `buildingGroupKey`（正規化物件名+区）単位で1行へ集約されている。
/// 従来は「現在のソート順で最初の戸」を代表にしていたが、ユーザーが知りたいのは
/// 「この建物のベスト戸はどれか」。そこで棟内で最も評価の高い戸を代表に選ぶ。
///
/// View の computed property に直接書くとテストが実装のコピーを検証することに
/// なるため、必ずここに集約する（WatchlistFilter と同じ方針）。
enum BuildingAggregator {

    /// ベスト戸の選定順（降順に強い）:
    ///   1. AI購入推奨度（★ 1-5）が高い
    ///   2. 総合投資スコア（listing_score）が高い
    ///   3. 価格が安い（棟内最安＝エントリー価格を代表にする）
    ///   4. URL（決定的なタイブレーク）
    ///
    /// `lhs` の方がベストなら true。
    static func isBetter(_ lhs: Listing, than rhs: Listing) -> Bool {
        let lScore = lhs.aiRecommendationScore ?? -1
        let rScore = rhs.aiRecommendationScore ?? -1
        if lScore != rScore { return lScore > rScore }

        let lListing = lhs.listingScore ?? -1
        let rListing = rhs.listingScore ?? -1
        if lListing != rListing { return lListing > rListing }

        let lPrice = lhs.priceMan ?? Int.max
        let rPrice = rhs.priceMan ?? Int.max
        if lPrice != rPrice { return lPrice < rPrice }

        return (lhs.url ?? "") < (rhs.url ?? "")
    }

    /// 棟内の戸群からベスト戸を返す。空配列なら nil。
    static func bestRepresentative(from units: [Listing]) -> Listing? {
        units.reduce(nil) { best, unit in
            guard let best else { return unit }
            return isBetter(unit, than: best) ? unit : best
        }
    }
}
