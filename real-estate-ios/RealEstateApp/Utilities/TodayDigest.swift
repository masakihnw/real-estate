import Foundation

/// 「今日」タブの朝刊ダイジェスト。
///
/// 掲載中物件から単一パスで「変化カード（最大5枚）」と「今日のひとこと（ブリーフ文）」を
/// 算出する。ブリーフ文は AI デイリーブリーフ導入までのローカル合成フォールバック。
/// `BuildingPreferenceStore` に依存せず、評価済み建物名を引数で受けるためテスト可能。
@MainActor
struct TodayDigest {

    /// 変化の種類。rawValue が小さいほどカードの先頭に並ぶ。
    enum ChangeKind: Int, Comparable, CaseIterable {
        case watchDrop = 0   // ウォッチ（いいね/S・A）物件の値下げ
        case priceDrop = 1   // 値下げ
        case relisted = 2    // 再掲載
        case newListing = 3  // 新着

        static func < (lhs: ChangeKind, rhs: ChangeKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .watchDrop:  "ウォッチ値下げ"
            case .priceDrop:  "値下げ"
            case .relisted:   "再掲載"
            case .newListing: "新着"
            }
        }

        var systemImage: String {
            switch self {
            case .watchDrop:  "heart.circle"
            case .priceDrop:  "arrow.down.circle"
            case .relisted:   "arrow.uturn.left.circle"
            case .newListing: "sparkles"
            }
        }
    }

    struct ChangeCard: Identifiable {
        let listing: Listing
        let kind: ChangeKind
        var id: String { listing.url }
    }

    static let maxCards = 5

    /// 変化カード（優先度順・建物単位で重複排除・最大5枚）
    let changeCards: [ChangeCard]
    /// 今日のひとこと（ローカル合成）
    let briefText: String
    /// 変化が1件もないか
    let hasNoChanges: Bool

    init(
        listings: [Listing],
        reviewedBuildingNames: Set<String> = [],
        pendingSwipeCount: Int = 0
    ) {
        var cards: [ChangeCard] = []
        var newCount = 0
        var newSGradeCount = 0
        var dropCount = 0
        var relistedCount = 0
        var biggestWatchDrop: Int = 0
        var seenBuildings = Set<String>()

        // 優先度の高い分類が先に建物枠を取れるよう、まず全件を分類してから優先度順に処理する
        var classified: [(kind: ChangeKind, listing: Listing)] = []

        for listing in listings where !listing.isDelisted {
            // 評価済み（like/nope）建物は表示しない
            let buildingName = String(listing.identityKey.prefix(while: { $0 != "|" }))
            if reviewedBuildingNames.contains(buildingName) { continue }

            let change = listing.latestPriceChange ?? 0
            if change < 0 {
                dropCount += 1
                if WatchlistFilter.isWatchlisted(listing) {
                    classified.append((.watchDrop, listing))
                    biggestWatchDrop = min(biggestWatchDrop, change)
                } else {
                    classified.append((.priceDrop, listing))
                }
            } else if listing.isRelisted && listing.isRecentlyAdded {
                relistedCount += 1
                classified.append((.relisted, listing))
            } else if listing.isRecentlyAdded {
                newCount += 1
                if listing.scoreGradeLetter == "S" { newSGradeCount += 1 }
                classified.append((.newListing, listing))
            }
        }

        // 優先度 → 種別内ソート（値下げは変動幅、新着系は追加日時）
        classified.sort { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            switch a.kind {
            case .watchDrop, .priceDrop:
                return abs(a.listing.latestPriceChange ?? 0) > abs(b.listing.latestPriceChange ?? 0)
            case .relisted, .newListing:
                return a.listing.addedAt > b.listing.addedAt
            }
        }

        for entry in classified {
            guard cards.count < Self.maxCards else { break }
            // 同一建物は優先度の高い1枚だけ
            guard seenBuildings.insert(entry.listing.buildingGroupKey).inserted else { continue }
            cards.append(ChangeCard(listing: entry.listing, kind: entry.kind))
        }

        self.changeCards = cards
        self.hasNoChanges = classified.isEmpty
        self.briefText = Self.composeBrief(
            newCount: newCount,
            newSGradeCount: newSGradeCount,
            dropCount: dropCount,
            relistedCount: relistedCount,
            biggestWatchDrop: biggestWatchDrop,
            pendingSwipeCount: pendingSwipeCount
        )
    }

    // MARK: - ブリーフ文の合成

    static func composeBrief(
        newCount: Int,
        newSGradeCount: Int,
        dropCount: Int,
        relistedCount: Int,
        biggestWatchDrop: Int,
        pendingSwipeCount: Int
    ) -> String {
        var parts: [String] = []
        if newCount > 0 {
            var part = "新着\(newCount)件"
            if newSGradeCount > 0 {
                part += "（うちS評価\(newSGradeCount)件）"
            }
            parts.append(part)
        }
        if dropCount > 0 { parts.append("値下げ\(dropCount)件") }
        if relistedCount > 0 { parts.append("再掲載\(relistedCount)件") }

        var sentences: [String] = []
        if parts.isEmpty {
            sentences.append("今日は動きなし。")
        } else {
            sentences.append(parts.joined(separator: "、") + "。")
        }
        if biggestWatchDrop < 0 {
            sentences.append("ウォッチ中の物件が▼\(abs(biggestWatchDrop))万。")
        }
        if pendingSwipeCount > 0 {
            sentences.append("新着スワイプが\(pendingSwipeCount)件待っています。")
        }
        return sentences.joined()
    }
}
