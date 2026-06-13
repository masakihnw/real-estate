import Testing
import Foundation
@testable import RealEstateApp

@Suite("SwipeProgressStore 進捗永続化")
struct SwipeProgressStoreTests {

    /// テストごとに独立した UserDefaults suite を使う。
    private func makeStore() -> (SwipeProgressStore, UserDefaults) {
        let suite = "test.swipe.progress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SwipeProgressStore(defaults: defaults), defaults)
    }

    @Test("初期状態は空配列")
    func emptyByDefault() {
        let (store, _) = makeStore()
        #expect(store.remainingKeys.isEmpty)
        #expect(store.skippedKeys.isEmpty)
    }

    @Test("remainingKeys / skippedKeys の保存と読込")
    func savesAndLoads() {
        let (store, _) = makeStore()
        store.remainingKeys = ["a", "b", "c"]
        store.skippedKeys = ["x", "y"]
        #expect(store.remainingKeys == ["a", "b", "c"])
        #expect(store.skippedKeys == ["x", "y"])
    }

    @Test("永続化は別インスタンスからも読める（UserDefaults backing）")
    func persistsAcrossInstances() {
        let suite = "test.swipe.progress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let writer = SwipeProgressStore(defaults: defaults)
        writer.remainingKeys = ["k1", "k2"]
        writer.skippedKeys = ["s1"]

        let reader = SwipeProgressStore(defaults: defaults)
        #expect(reader.remainingKeys == ["k1", "k2"])
        #expect(reader.skippedKeys == ["s1"])
    }

    @Test("clearRemaining は残りデッキのみ消し skippedKeys は保持")
    func clearRemainingKeepsSkipped() {
        let (store, _) = makeStore()
        store.remainingKeys = ["a", "b"]
        store.skippedKeys = ["s1", "s2"]
        store.clearRemaining()
        #expect(store.remainingKeys.isEmpty)
        #expect(store.skippedKeys == ["s1", "s2"])
    }

    @Test("clearAll は両方消す")
    func clearAllWipesBoth() {
        let (store, _) = makeStore()
        store.remainingKeys = ["a"]
        store.skippedKeys = ["s"]
        store.clearAll()
        #expect(store.remainingKeys.isEmpty)
        #expect(store.skippedKeys.isEmpty)
    }
}
