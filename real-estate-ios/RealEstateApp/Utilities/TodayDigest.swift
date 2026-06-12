import Foundation

/// 「今日」タブの朝刊ダイジェスト。
///
/// 掲載中物件から単一パスで「変化カード（最大5枚）」「今日のひとこと（ブリーフ文）」
/// 「週次相場（スコア分布・区別ランキング）」を算出する。
/// ブリーフ文は AI デイリーブリーフ導入までのローカル合成フォールバック。
///
/// テスタビリティ:
/// - `BuildingPreferenceStore` に依存せず、評価済み建物名を引数で受ける
/// - `now` を注入可能（値下げの期間ゲート判定を決定的にテストできる）
///
/// 除外ルール:
/// - 評価済み（like/nope）建物は「新着・再掲載」からのみ除外する。
///   値下げ系には適用しない — like 済み建物こそウォッチ値下げの主対象のため。
@MainActor
struct TodayDigest {

    /// 変化の種類。rawValue が小さいほどカードの先頭に並ぶ。
    /// 再掲載は「売り急ぎ・価格交渉余地のシグナル」のため新着より優先する。
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

    /// 週次相場: スコア分布
    struct ScoreGrades {
        var s = 0, a = 0, b = 0, c = 0, d = 0
        var maxCount: Int { max(max(max(s, a), max(b, c)), max(d, 1)) }
    }

    /// 週次相場: 区別の平均スコアランキング
    struct WardRanking: Hashable {
        let ward: String
        let avgScore: Int
        let count: Int
    }

    static let maxCards = 5
    /// 値下げを「最近の変化」とみなす期間（日）。TimelineFeed と同じ基準。
    static let priceDropWindowDays = 7

    /// 変化カード（優先度順・建物単位で重複排除・最大5枚）
    let changeCards: [ChangeCard]
    /// 今日のひとこと（ローカル合成）
    let briefText: String
    /// 変化が1件もないか
    let hasNoChanges: Bool
    /// スコア分布（週次相場カード用）
    let scoreGrades: ScoreGrades
    /// 区別平均スコア Top5（週次相場カード用）
    let wardRankings: [WardRanking]

    init(
        listings: [Listing],
        reviewedBuildingNames: Set<String> = [],
        pendingSwipeCount: Int = 0,
        now: Date = Date()
    ) {
        var newBuildings = Set<String>()
        var newSGradeCount = 0
        var dropCount = 0
        var relistedCount = 0
        var biggestWatchDrop = 0
        var grades = ScoreGrades()
        var wardData: [String: (totalScore: Int, count: Int)] = [:]
        let thresholds = DesignSystem.gradeThresholds

        // 優先度の高い分類が先に建物枠を取れるよう、まず全件を分類してから優先度順に処理する
        var classified: [(kind: ChangeKind, listing: Listing)] = []

        for listing in listings where !listing.isDelisted {
            // 週次相場の集計（変化の有無に関係なく全掲載中物件が対象）
            if let score = listing.listingScore {
                switch thresholds.grade(for: score) {
                case "S": grades.s += 1
                case "A": grades.a += 1
                case "B": grades.b += 1
                case "C": grades.c += 1
                default:  grades.d += 1
                }
                let ward = listing.wardName
                if !ward.isEmpty {
                    let entry = wardData[ward] ?? (0, 0)
                    wardData[ward] = (entry.totalScore + score, entry.count + 1)
                }
            }

            // 値下げ: 期間内の価格変動のみ（定義は TimelineFeed.recentPriceChange と共有）
            if let recent = TimelineFeed.recentPriceChange(
                of: listing, days: Self.priceDropWindowDays, now: now
            ), recent.change < 0 {
                let change = recent.change
                if WatchlistFilter.isWatchlisted(listing) {
                    // ウォッチ値下げはブリーフで専用文（▼N万）になるため
                    // 「値下げN件」には数えない（二重表現の防止）
                    classified.append((.watchDrop, listing))
                    biggestWatchDrop = min(biggestWatchDrop, change)
                } else {
                    dropCount += 1
                    classified.append((.priceDrop, listing))
                }
                continue
            }

            // 新着・再掲載: 評価済み建物は除外（既に判断済みのため）
            let buildingName = String(listing.identityKey.prefix(while: { $0 != "|" }))
            guard !reviewedBuildingNames.contains(buildingName) else { continue }

            if listing.isRelisted && listing.isRecentlyAdded {
                relistedCount += 1
                classified.append((.relisted, listing))
            } else if listing.isRecentlyAdded {
                // ブリーフの件数は建物単位（カードの重複排除と同じ数え方）
                if newBuildings.insert(listing.buildingGroupKey).inserted {
                    if listing.scoreGradeLetter == "S" { newSGradeCount += 1 }
                }
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

        var cards: [ChangeCard] = []
        var seenBuildings = Set<String>()
        for entry in classified {
            guard cards.count < Self.maxCards else { break }
            // 同一建物は優先度の高い1枚だけ
            guard seenBuildings.insert(entry.listing.buildingGroupKey).inserted else { continue }
            cards.append(ChangeCard(listing: entry.listing, kind: entry.kind))
        }

        self.changeCards = cards
        self.hasNoChanges = classified.isEmpty
        self.scoreGrades = grades
        self.wardRankings = wardData
            .map { WardRanking(ward: $0.key, avgScore: $0.value.totalScore / max($0.value.count, 1), count: $0.value.count) }
            .sorted { $0.avgScore > $1.avgScore }
            .prefix(5)
            .map { $0 }
        self.briefText = Self.composeBrief(
            newCount: newBuildings.count,
            newSGradeCount: newSGradeCount,
            dropCount: dropCount,
            relistedCount: relistedCount,
            biggestWatchDrop: biggestWatchDrop,
            pendingSwipeCount: pendingSwipeCount
        )
    }

    // MARK: - ブリーフ文の合成

    /// ブリーフ文を合成する。
    /// 不変条件: `biggestWatchDrop < 0` のとき `dropCount > 0` であること（init 経由では常に成立）。
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
            // ウォッチ変動だけがある異常系でも「動きなし」とは言わない
            if biggestWatchDrop >= 0 {
                sentences.append("今日は動きなし。")
            }
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
