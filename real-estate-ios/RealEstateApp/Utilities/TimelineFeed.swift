import Foundation

/// ダッシュボードの時系列フィード。
///
/// 新着・値下げ・値上げ・再掲のイベントを日付降順の1本のタイムラインに統合する。
/// パイプラインが計算済みの addedAt / priceHistory / isRelisted を表示層で
/// 組み立てるだけで、新しいデータ取得は不要。
struct TimelineFeedItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case added
        case relisted
        case priceDrop(amount: Int)
        case priceRaise(amount: Int)

        var label: String {
            switch self {
            case .added: return "新着"
            case .relisted: return "再掲"
            case .priceDrop: return "値下げ"
            case .priceRaise: return "値上げ"
            }
        }

        var systemImage: String {
            switch self {
            case .added: return "sparkles"
            case .relisted: return "arrow.counterclockwise.circle.fill"
            case .priceDrop: return "arrow.down.circle.fill"
            case .priceRaise: return "arrow.up.circle.fill"
            }
        }
    }

    let id: String
    let date: Date
    let kind: Kind
    let listing: Listing

    static func == (lhs: TimelineFeedItem, rhs: TimelineFeedItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum TimelineFeed {

    /// 直近 `days` 日以内に確定した価格変動（履歴の最終エントリ基準）。
    /// 「最近の価格変動」の定義は TodayDigest と本フィードで共有する単一実装。
    /// - Returns: (変動額, 変動日)。期間外・履歴不足・変動なしは nil。
    static func recentPriceChange(
        of listing: Listing,
        days: Int = 7,
        now: Date = Date()
    ) -> (change: Int, date: Date)? {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return nil
        }
        let history = listing.parsedPriceHistory
        guard history.count >= 2,
              let lastDate = history.last?.parsedDate,
              lastDate >= cutoff,
              let change = listing.latestPriceChange,
              change != 0 else { return nil }
        return (change, lastDate)
    }

    /// 直近 `days` 日以内のイベントを日付降順で最大 `limit` 件返す。
    static func build(
        from listings: [Listing],
        days: Int = 7,
        limit: Int = 15,
        now: Date = Date()
    ) -> [TimelineFeedItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return []
        }
        var items: [TimelineFeedItem] = []

        for listing in listings {
            // 新着 / 再掲（追加日ベース）
            if listing.addedAt >= cutoff {
                let kind: TimelineFeedItem.Kind = listing.isRelisted ? .relisted : .added
                items.append(TimelineFeedItem(
                    id: "\(listing.url)#added",
                    date: listing.addedAt,
                    kind: kind,
                    listing: listing
                ))
            }

            // 直近の価格変動（履歴の最終エントリが期間内の場合）
            if let recent = recentPriceChange(of: listing, days: days, now: now) {
                items.append(TimelineFeedItem(
                    id: "\(listing.url)#price",
                    date: recent.date,
                    kind: recent.change < 0
                        ? .priceDrop(amount: abs(recent.change))
                        : .priceRaise(amount: recent.change),
                    listing: listing
                ))
            }
        }

        return Array(
            items
                .sorted { $0.date > $1.date }
                .prefix(limit)
        )
    }
}
