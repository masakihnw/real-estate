import Testing
import Foundation
@testable import RealEstateApp

@Suite("SwipeSession 進捗永続化の統合")
@MainActor
struct SwipeSessionPersistenceTests {

    private nonisolated(unsafe) static var counter = 0

    private func makeListing() -> Listing {
        SwipeSessionPersistenceTests.counter += 1
        let unique = "persist_\(SwipeSessionPersistenceTests.counter)_\(UUID().uuidString.prefix(8))"
        return Listing(url: "https://test.example.com/\(unique)", name: unique, propertyType: "chuko")
    }

    private func makeStore() -> SwipeProgressStore {
        let suite = "test.swipe.session.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SwipeProgressStore(defaults: defaults)
    }

    @Test("commitSwipe で残りデッキ（currentIndex以降）が永続化される")
    func commitPersistsRemaining() {
        let store = makeStore()
        let vm = SwipeSessionViewModel(progressStore: store)
        let cards = [makeListing(), makeListing(), makeListing()]
        vm.setCardsForTesting(cards)

        vm.commitSwipe(.like)
        #expect(store.remainingKeys == [cards[1].identityKey, cards[2].identityKey])
    }

    @Test("skip でキーが skippedKeys に追加される")
    func skipAddsToSkippedKeys() {
        let store = makeStore()
        let vm = SwipeSessionViewModel(progressStore: store)
        let cards = [makeListing(), makeListing()]
        vm.setCardsForTesting(cards)

        vm.commitSwipe(.skip)
        #expect(store.skippedKeys == [cards[0].identityKey])
    }

    @Test("like/nope は skippedKeys から除去する")
    func decideRemovesFromSkipped() {
        let store = makeStore()
        let vm = SwipeSessionViewModel(progressStore: store)
        let cards = [makeListing(), makeListing()]
        store.skippedKeys = [cards[0].identityKey]
        vm.setCardsForTesting(cards)

        vm.commitSwipe(.like)
        #expect(store.skippedKeys.isEmpty)
    }

    @Test("デッキ完走で remainingKeys がクリアされ skippedKeys は保持")
    func completeClearsRemainingKeepsSkipped() {
        let store = makeStore()
        let vm = SwipeSessionViewModel(progressStore: store)
        let cards = [makeListing(), makeListing()]
        vm.setCardsForTesting(cards)

        vm.commitSwipe(.skip)   // cards[0] → skipped
        vm.commitSwipe(.like)   // cards[1] → 完走
        #expect(vm.isComplete)
        #expect(store.remainingKeys.isEmpty)
        #expect(store.skippedKeys == [cards[0].identityKey])
    }

    @Test("undo で残りデッキが戻り、直前 skip は取り消される")
    func undoRestoresRemainingAndSkip() {
        let store = makeStore()
        let vm = SwipeSessionViewModel(progressStore: store)
        let cards = [makeListing(), makeListing(), makeListing()]
        vm.setCardsForTesting(cards)

        vm.commitSwipe(.skip)   // cards[0] skipped, index=1
        #expect(store.skippedKeys == [cards[0].identityKey])
        vm.undo()               // 取り消し → index=0
        #expect(store.skippedKeys.isEmpty)
        #expect(store.remainingKeys == cards.map(\.identityKey))
    }

    @Test("restoreDeckOrder で前回 skip した物件が先頭に再登場")
    func restoreResurfacesSkippedFirst() {
        let store = makeStore()
        let cards = [makeListing(), makeListing(), makeListing()]
        // 前回セッション: cards[2] を「あとで」、残りは [cards[0], cards[1]]
        store.skippedKeys = [cards[2].identityKey]
        store.remainingKeys = [cards[0].identityKey, cards[1].identityKey]

        let vm = SwipeSessionViewModel(progressStore: store)
        vm.setCardsForTesting(cards)   // eligible = 全3件
        vm.restoreDeckOrder()

        #expect(vm.cards.first?.identityKey == cards[2].identityKey)
        #expect(vm.cards.map(\.identityKey) == [
            cards[2].identityKey, cards[0].identityKey, cards[1].identityKey,
        ])
        #expect(vm.currentIndex == 0)
    }

    @Test("restoreDeckOrder は eligible 外の skippedKeys を剪定して再保存")
    func restorePrunesStaleSkipped() {
        let store = makeStore()
        let cards = [makeListing(), makeListing()]
        store.skippedKeys = [cards[0].identityKey, "stale-gone-key"]

        let vm = SwipeSessionViewModel(progressStore: store)
        vm.setCardsForTesting(cards)
        vm.restoreDeckOrder()

        #expect(store.skippedKeys == [cards[0].identityKey])
    }
}
