import Testing
import Foundation
@testable import RealEstateApp

@MainActor
@Suite("TodayDigest 朝刊ダイジェスト")
struct TodayDigestTests {

    // MARK: - Helpers

    private func makeListing(
        url: String,
        name: String,
        addedDaysAgo: Double = 10,
        priceHistory: [(String, Int)] = [],
        isRelisted: Bool = false,
        isDelisted: Bool = false,
        isLiked: Bool = false,
        assetGrade: String? = nil
    ) -> Listing {
        let l = Listing(url: url, name: name, propertyType: "chuko")
        l.addedAt = Date().addingTimeInterval(-addedDaysAgo * 24 * 3600)
        l.isRelisted = isRelisted
        l.isDelisted = isDelisted
        l.isLiked = isLiked
        l.assetGrade = assetGrade
        if !priceHistory.isEmpty {
            let entries = priceHistory
                .map { #"{"date":"\#($0.0)","price_man":\#($0.1)}"# }
                .joined(separator: ",")
            l.priceHistoryJSON = "[\(entries)]"
        }
        return l
    }

    // MARK: - 変化カード

    @Test("新着（2日以内追加）が newListing カードになる")
    func newListingCard() {
        let l = makeListing(url: "https://x/1", name: "新着マンション", addedDaysAgo: 1)
        let digest = TodayDigest(listings: [l])
        #expect(digest.changeCards.count == 1)
        #expect(digest.changeCards.first?.kind == .newListing)
    }

    @Test("値下げ履歴のある物件は priceDrop、いいね済みなら watchDrop")
    func dropKinds() {
        let drop = makeListing(
            url: "https://x/1", name: "値下げ物件",
            priceHistory: [("2026-06-01", 10_000), ("2026-06-10", 9_800)]
        )
        let watch = makeListing(
            url: "https://x/2", name: "ウォッチ物件",
            priceHistory: [("2026-06-01", 12_500), ("2026-06-10", 12_300)],
            isLiked: true
        )
        let digest = TodayDigest(listings: [drop, watch])
        #expect(digest.changeCards.count == 2)
        // watchDrop が priceDrop より先頭
        #expect(digest.changeCards[0].kind == .watchDrop)
        #expect(digest.changeCards[1].kind == .priceDrop)
    }

    @Test("カードは最大5枚")
    func maxFiveCards() {
        let listings = (1...8).map {
            makeListing(url: "https://x/\($0)", name: "物件\($0)号棟", addedDaysAgo: 1)
        }
        let digest = TodayDigest(listings: listings)
        #expect(digest.changeCards.count == TodayDigest.maxCards)
    }

    @Test("掲載終了物件はカードに含まれない")
    func excludesDelisted() {
        let l = makeListing(url: "https://x/1", name: "終了物件", addedDaysAgo: 1, isDelisted: true)
        let digest = TodayDigest(listings: [l])
        #expect(digest.changeCards.isEmpty)
        #expect(digest.hasNoChanges)
    }

    @Test("評価済み建物はカードに含まれない")
    func excludesReviewedBuildings() {
        let l = makeListing(url: "https://x/1", name: "評価済みマンション", addedDaysAgo: 1)
        let buildingName = String(l.identityKey.prefix(while: { $0 != "|" }))
        let digest = TodayDigest(listings: [l], reviewedBuildingNames: [buildingName])
        #expect(digest.changeCards.isEmpty)
    }

    @Test("同一建物は優先度の高い1枚に集約される")
    func dedupsSameBuilding() {
        // 同名建物の2住戸: 片方は値下げ、片方は新着
        let dropUnit = makeListing(
            url: "https://x/1", name: "パークタワー",
            priceHistory: [("2026-06-01", 10_000), ("2026-06-10", 9_700)]
        )
        let newUnit = makeListing(url: "https://x/2", name: "パークタワー", addedDaysAgo: 1)
        let digest = TodayDigest(listings: [dropUnit, newUnit])
        #expect(digest.changeCards.count == 1)
        #expect(digest.changeCards.first?.kind == .priceDrop)
    }

    @Test("再掲載（2日以内）は relisted カードになり、新着より優先")
    func relistedCard() {
        let l = makeListing(url: "https://x/1", name: "再掲載物件", addedDaysAgo: 1, isRelisted: true)
        let digest = TodayDigest(listings: [l])
        #expect(digest.changeCards.first?.kind == .relisted)
    }

    // MARK: - ブリーフ文

    @Test("変化なし・スワイプ残なし → 「今日は動きなし。」")
    func briefNoChanges() {
        let digest = TodayDigest(listings: [])
        #expect(digest.briefText == "今日は動きなし。")
        #expect(digest.hasNoChanges)
    }

    @Test("変化なし・スワイプ残あり → スワイプ案内を付加")
    func briefNoChangesWithPending() {
        let digest = TodayDigest(listings: [], pendingSwipeCount: 5)
        #expect(digest.briefText == "今日は動きなし。新着スワイプが5件待っています。")
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

    @Test("再掲載を含む文")
    func briefWithRelisted() {
        let text = TodayDigest.composeBrief(
            newCount: 0, newSGradeCount: 0,
            dropCount: 0, relistedCount: 1,
            biggestWatchDrop: 0, pendingSwipeCount: 0
        )
        #expect(text == "再掲載1件。")
    }
}
