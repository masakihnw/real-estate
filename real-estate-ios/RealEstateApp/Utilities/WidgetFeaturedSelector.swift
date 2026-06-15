import Foundation

/// ウィジェットの「今日の1枚」に出す物件の表示用スナップショット。
/// app 側で算出し、WidgetDataProvider が App Group の JSON へ書き出す。
struct FeaturedListing: Equatable {
    /// ディープリンク解決用（Spotlight と同じく listing.url を識別子に使う）
    let url: String
    let name: String
    let priceText: String
    let gradeLetter: String?
    let score: Int?
    /// サムネイル画像の取得元（App Group へのダウンロード元）。無ければ nil。
    let imageURLString: String?
}

/// 「今日の1枚」を選ぶ純関数。
///
/// 変化カード（新着）の先頭に相当する物件を選ぶ。ローカルには価格履歴が無いため
/// 値下げ検出は行わず、新着（`isRecentlyAdded` かつ掲載中）のうち listingScore 最高、
/// 同点は addedAt が新しい順で先頭を採る。Today タブの「今日の動き」と整合する。
enum WidgetFeaturedSelector {

    /// 先頭1件（small ウィジェット用）。
    static func select(from listings: [Listing]) -> FeaturedListing? {
        selectTop(from: listings, limit: 1).first
    }

    /// 上位 limit 件（medium ウィジェットの「2物件」用）。
    static func selectTop(from listings: [Listing], limit: Int = 2) -> [FeaturedListing] {
        listings
            .filter { $0.isRecentlyAdded && !$0.isDelisted }
            .filter(GradeVisibility.isVisible)   // D評価は発見導線（ウィジェット）に出さない
            .sorted { lhs, rhs in
                let ls = lhs.listingScore ?? 0
                let rs = rhs.listingScore ?? 0
                if ls != rs { return ls > rs }
                return lhs.addedAt > rhs.addedAt
            }
            .prefix(limit)
            .map { top in
                FeaturedListing(
                    url: top.url,
                    name: top.nameWithFloor,
                    priceText: top.priceDisplayCompact,
                    gradeLetter: top.scoreGradeLetter,
                    score: top.listingScore,
                    imageURLString: top.thumbnailURL?.absoluteString
                )
            }
    }
}
