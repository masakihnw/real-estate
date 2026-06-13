import Testing
import Foundation
@testable import RealEstateApp

@Suite("SwipeDeckBuilder デッキ並び構築")
struct SwipeDeckBuilderTests {

    private nonisolated(unsafe) static var counter = 0

    /// 一意な名前で Listing を作る。identityKey は name 由来で一意になる。
    private func makeListing(score: Int) -> Listing {
        SwipeDeckBuilderTests.counter += 1
        let unique = "deck_\(SwipeDeckBuilderTests.counter)_\(UUID().uuidString.prefix(8))"
        return Listing(
            url: "https://test.example.com/\(unique)",
            name: unique,
            propertyType: "chuko",
            listingScore: score
        )
    }

    @Test("保存進捗なしは listingScore 降順")
    func noSavedProgressSortsByScore() {
        let low = makeListing(score: 10)
        let high = makeListing(score: 90)
        let mid = makeListing(score: 50)
        let deck = SwipeDeckBuilder.build(eligible: [low, high, mid])
        #expect(deck.map(\.listingScore) == [90, 50, 10])
    }

    @Test("skippedKeys が先頭、続いて remaining、続いて新規（score降順）")
    func ordersSkippedThenRemainingThenFresh() {
        let skipped = makeListing(score: 5)     // 低スコアでも skip なので先頭
        let remaining = makeListing(score: 20)
        let freshHigh = makeListing(score: 99)
        let freshLow = makeListing(score: 30)

        let deck = SwipeDeckBuilder.build(
            eligible: [freshLow, remaining, freshHigh, skipped],
            savedRemainingKeys: [remaining.identityKey],
            skippedKeys: [skipped.identityKey]
        )
        #expect(deck.map(\.identityKey) == [
            skipped.identityKey,      // ① skip
            remaining.identityKey,    // ② remaining
            freshHigh.identityKey,    // ③ fresh score 99
            freshLow.identityKey,     //    fresh score 30
        ])
    }

    @Test("eligible に存在しない保存キーは除外される")
    func dropsKeysNotInEligible() {
        let present = makeListing(score: 50)
        let deck = SwipeDeckBuilder.build(
            eligible: [present],
            savedRemainingKeys: ["gone-remaining-key"],
            skippedKeys: ["gone-skipped-key"]
        )
        #expect(deck.map(\.identityKey) == [present.identityKey])
    }

    @Test("skip と remaining 両方に同じキーがあれば skip 優先で1回だけ")
    func dedupesSkipWins() {
        let dup = makeListing(score: 40)
        let other = makeListing(score: 80)
        let deck = SwipeDeckBuilder.build(
            eligible: [other, dup],
            savedRemainingKeys: [dup.identityKey],
            skippedKeys: [dup.identityKey]
        )
        // dup は先頭に1回だけ、other は fresh として後ろ
        #expect(deck.map(\.identityKey) == [dup.identityKey, other.identityKey])
        #expect(deck.count == 2)
    }

    @Test("skippedKeys / remainingKeys の指定順が保たれる")
    func preservesSavedOrder() {
        let a = makeListing(score: 1)
        let b = makeListing(score: 2)
        let c = makeListing(score: 3)
        let deck = SwipeDeckBuilder.build(
            eligible: [a, b, c],
            savedRemainingKeys: [c.identityKey, a.identityKey, b.identityKey],
            skippedKeys: []
        )
        #expect(deck.map(\.identityKey) == [c.identityKey, a.identityKey, b.identityKey])
    }

    @Test("空 eligible は空デッキ")
    func emptyEligible() {
        let deck = SwipeDeckBuilder.build(
            eligible: [],
            savedRemainingKeys: ["x"],
            skippedKeys: ["y"]
        )
        #expect(deck.isEmpty)
    }
}
