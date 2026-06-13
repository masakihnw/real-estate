import Foundation

/// 保存フィルタ（FilterTemplate）と新着物件のマッチ判定。
///
/// さがすタブのチップバッジと条件マッチ通知の両方から参照する単一実装。
/// 判定本体は `ListingFilter.apply(to:)` を再利用し、独自の条件解釈を持たない。
enum FilterMatchCounter {

    /// 「新着」の定義（Today・スワイプと同一: 2日以内追加かつ掲載中）
    static func newListings(in listings: [Listing]) -> [Listing] {
        listings.filter { $0.isRecentlyAdded && !$0.isDelisted }
    }

    /// テンプレートID → 新着マッチ件数（0件のテンプレートは含まない）
    static func matchCounts(
        newListings: [Listing],
        templates: [FilterTemplate]
    ) -> [UUID: Int] {
        guard !newListings.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        for template in templates {
            let count = template.filter.apply(to: newListings).count
            if count > 0 { counts[template.id] = count }
        }
        return counts
    }

    /// 通知本文用: テンプレート名と件数をマッチ数降順で返す（0件は除外）
    static func matchSummaries(
        newListings: [Listing],
        templates: [FilterTemplate]
    ) -> [(name: String, count: Int)] {
        let counts = matchCounts(newListings: newListings, templates: templates)
        return templates
            .compactMap { template in
                counts[template.id].map { (name: template.name, count: $0) }
            }
            .sorted { $0.count > $1.count }
    }
}
