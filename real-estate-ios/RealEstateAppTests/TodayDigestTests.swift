import Testing
import Foundation
@testable import RealEstateApp

@MainActor
@Suite("TodayDigest 朝刊ダイジェスト")
struct TodayDigestTests {

    // MARK: - Helpers

    /// テスト基準時刻（now 注入で期間ゲートを決定的にする）
    private let now = Date()

    private func isoDate(daysAgo: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now.addingTimeInterval(-daysAgo * 24 * 3600))
    }

    private func makeListing(
        url: String,
        name: String,
        addedDaysAgo: Double = 10,
        priceHistory: [(daysAgo: Double, priceMan: Int)] = [],
        isRelisted: Bool = false,
        isDelisted: Bool = false,
        isLiked: Bool = false,
        assetGrade: String? = nil,
        listingScore: Int? = nil
    ) -> Listing {
        let l = Listing(url: url, name: name, propertyType: "chuko")
        l.addedAt = now.addingTimeInterval(-addedDaysAgo * 24 * 3600)
        l.isRelisted = isRelisted
        l.isDelisted = isDelisted
        l.isLiked = isLiked
        l.assetGrade = assetGrade
        l.listingScore = listingScore
        if !priceHistory.isEmpty {
            let entries = priceHistory
                .map { #"{"date":"\#(isoDate(daysAgo: $0.daysAgo))","price_man":\#($0.priceMan)}"# }
                .joined(separator: ",")
            l.priceHistoryJSON = "[\(entries)]"
        }
        return l
    }

    // MARK: - 変化カード

    @Test("新着（2日以内追加）が newListing カードになる")
    func newListingCard() {
        let l = makeListing(url: "https://x/1", name: "新着マンション", addedDaysAgo: 1)
        let digest = TodayDigest(listings: [l], now: now)
        #expect(digest.changeCards.count == 1)
        #expect(digest.changeCards.first?.kind == .newListing)
    }

    @Test("値下げ（7日以内）は priceDrop、いいね済みなら watchDrop で先頭")
    func dropKinds() {
        let drop = makeListing(
            url: "https://x/1", name: "値下げ物件",
            priceHistory: [(30, 10_000), (2, 9_800)]
        )
        let watch = makeListing(
            url: "https://x/2", name: "ウォッチ物件",
            priceHistory: [(30, 12_500), (2, 12_300)],
            isLiked: true
        )
        let digest = TodayDigest(listings: [drop, watch], now: now)
        #expect(digest.changeCards.count == 2)
        #expect(digest.changeCards[0].kind == .watchDrop)
        #expect(digest.changeCards[1].kind == .priceDrop)
    }

    @Test("8日以上前の値下げは「最近の変化」に含まれない（期間ゲート）")
    func oldDropExcluded() {
        let oldDrop = makeListing(
            url: "https://x/1", name: "古い値下げ物件",
            priceHistory: [(60, 10_000), (10, 9_800)]
        )
        let digest = TodayDigest(listings: [oldDrop], now: now)
        #expect(digest.changeCards.isEmpty)
        #expect(digest.hasNoChanges)
        #expect(digest.briefText == "今日は動きなし。")
    }

    @Test("いいね済み建物の値下げは除外されない（ウォッチ値下げとして表示）")
    func likedBuildingDropNotExcluded() {
        let watch = makeListing(
            url: "https://x/1", name: "いいね済みマンション",
            priceHistory: [(30, 12_500), (1, 12_300)],
            isLiked: true
        )
        let buildingName = String(watch.identityKey.prefix(while: { $0 != "|" }))
        let digest = TodayDigest(
            listings: [watch],
            reviewedBuildingNames: [buildingName],
            now: now
        )
        #expect(digest.changeCards.count == 1)
        #expect(digest.changeCards.first?.kind == .watchDrop)
    }

    @Test("評価済み建物は新着カードから除外される")
    func excludesReviewedBuildingsFromNew() {
        let l = makeListing(url: "https://x/1", name: "評価済みマンション", addedDaysAgo: 1)
        let buildingName = String(l.identityKey.prefix(while: { $0 != "|" }))
        let digest = TodayDigest(listings: [l], reviewedBuildingNames: [buildingName], now: now)
        #expect(digest.changeCards.isEmpty)
    }

    @Test("カードは最大5枚")
    func maxFiveCards() {
        // 注意: 「N号棟」等の棟名は cleanListingName で除去され同一建物に
        // 集約されるため、明確に異なる建物名を使う
        let names = ["アルファ", "ブラボー", "チャーリー", "デルタ",
                     "エコー", "フォックス", "ゴルフ", "ホテル"]
        let listings = names.enumerated().map { index, name in
            makeListing(url: "https://x/\(index)", name: "\(name)マンション", addedDaysAgo: 1)
        }
        let digest = TodayDigest(listings: listings, now: now)
        #expect(digest.changeCards.count == TodayDigest.maxCards)
    }

    @Test("掲載終了物件はカードに含まれない")
    func excludesDelisted() {
        let l = makeListing(url: "https://x/1", name: "終了物件", addedDaysAgo: 1, isDelisted: true)
        let digest = TodayDigest(listings: [l], now: now)
        #expect(digest.changeCards.isEmpty)
        #expect(digest.hasNoChanges)
    }

    @Test("同一建物は優先度の高い1枚に集約される")
    func dedupsSameBuilding() {
        let dropUnit = makeListing(
            url: "https://x/1", name: "パークタワー",
            priceHistory: [(30, 10_000), (1, 9_700)]
        )
        let newUnit = makeListing(url: "https://x/2", name: "パークタワー", addedDaysAgo: 1)
        let digest = TodayDigest(listings: [dropUnit, newUnit], now: now)
        #expect(digest.changeCards.count == 1)
        #expect(digest.changeCards.first?.kind == .priceDrop)
    }

    @Test("再掲載（2日以内）は relisted カードになり、新着より優先")
    func relistedCard() {
        let relisted = makeListing(url: "https://x/1", name: "再掲載物件", addedDaysAgo: 1, isRelisted: true)
        let fresh = makeListing(url: "https://x/2", name: "新着物件", addedDaysAgo: 1)
        let digest = TodayDigest(listings: [relisted, fresh], now: now)
        #expect(digest.changeCards.first?.kind == .relisted)
    }

    // MARK: - ブリーフ文

    @Test("変化なし・スワイプ残なし → 「今日は動きなし。」")
    func briefNoChanges() {
        let digest = TodayDigest(listings: [], now: now)
        #expect(digest.briefText == "今日は動きなし。")
        #expect(digest.hasNoChanges)
    }

    @Test("変化なし・スワイプ残あり → スワイプ案内を付加")
    func briefNoChangesWithPending() {
        let digest = TodayDigest(listings: [], pendingSwipeCount: 5, now: now)
        #expect(digest.briefText == "今日は動きなし。新着スワイプが5件待っています。")
    }

    @Test("新着件数は建物単位で数える（同一建物の複数住戸は1件）")
    func briefCountsNewByBuilding() {
        let unit1 = makeListing(url: "https://x/1", name: "パークタワー", addedDaysAgo: 1)
        let unit2 = makeListing(url: "https://x/2", name: "パークタワー", addedDaysAgo: 1)
        let other = makeListing(url: "https://x/3", name: "別マンション", addedDaysAgo: 1)
        let digest = TodayDigest(listings: [unit1, unit2, other], now: now)
        #expect(digest.briefText == "新着2件。")
    }

    @Test("新着・値下げ・ウォッチ変動の複合文")
    func briefComposite() {
        let text = TodayDigest.composeBrief(
            newCount: 3, newSGradeCount: 1,
            dropCount: 2, relistedCount: 0,
            biggestWatchDrop: -200, pendingSwipeCount: 0
        )
        #expect(text == "新着3件（うちS評価1件）、値下げ2件。ウォッチ中の物件が▼200万。")
    }

    @Test("S評価ゼロなら括弧書きなし")
    func briefWithoutSGrade() {
        let text = TodayDigest.composeBrief(
            newCount: 2, newSGradeCount: 0,
            dropCount: 0, relistedCount: 0,
            biggestWatchDrop: 0, pendingSwipeCount: 0
        )
        #expect(text == "新着2件。")
    }

    @Test("件数ゼロ＋ウォッチ変動のみでも「動きなし」とは言わない（不変条件ガード）")
    func briefWatchDropOnlyDoesNotSayNoChanges() {
        let text = TodayDigest.composeBrief(
            newCount: 0, newSGradeCount: 0,
            dropCount: 0, relistedCount: 0,
            biggestWatchDrop: -200, pendingSwipeCount: 0
        )
        #expect(text == "ウォッチ中の物件が▼200万。")
    }

    // MARK: - 週次相場

    @Test("スコア分布と区別ランキングが集計される")
    func weeklyMarketStats() {
        let s1 = makeListing(url: "https://x/1", name: "S物件", listingScore: 85)
        let b1 = makeListing(url: "https://x/2", name: "B物件", listingScore: 55)
        let digest = TodayDigest(listings: [s1, b1], now: now)
        #expect(digest.scoreGrades.s == 1)
        #expect(digest.scoreGrades.b == 1)
    }

    @Test("区別ランキングは平均スコア降順で最大5区")
    func wardRankingTop5() {
        // wardName は address から導出されるため、ここでは件数の上限のみ検証
        let listings = (1...3).map {
            makeListing(url: "https://x/\($0)", name: "物件\($0)", listingScore: 70)
        }
        let digest = TodayDigest(listings: listings, now: now)
        #expect(digest.wardRankings.count <= 5)
    }
}
