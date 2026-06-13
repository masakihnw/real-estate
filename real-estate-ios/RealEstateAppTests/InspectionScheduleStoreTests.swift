import Testing
import Foundation
@testable import RealEstateApp

@Suite("InspectionScheduleStore 内見予定フラグ")
@MainActor
struct InspectionScheduleStoreTests {

    private func makeStore() -> (InspectionScheduleStore, UserDefaults) {
        let suite = "test.inspection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (InspectionScheduleStore(defaults: defaults), defaults)
    }

    private nonisolated(unsafe) static var counter = 0

    private func listing() -> Listing {
        // identityKey は URL でなく 名前|間取り|面積|住所|築年 で決まる。名前は cleanListingName で
        // 正規化され一意サフィックスが消えるため、生のまま含まれる builtYear を物件ごとに変えて分離する。
        Self.counter += 1
        return Listing(url: "https://x/\(UUID().uuidString)", name: "物件", builtYear: 1980 + Self.counter, propertyType: "chuko")
    }

    @Test("初期状態は未予定")
    func emptyByDefault() {
        let (store, _) = makeStore()
        #expect(store.scheduledKeys.isEmpty)
        #expect(!store.isScheduled(listing()))
    }

    @Test("setScheduled で予定の追加・解除")
    func setScheduled() {
        let (store, _) = makeStore()
        let l = listing()
        store.setScheduled(true, for: l)
        #expect(store.isScheduled(l))
        store.setScheduled(false, for: l)
        #expect(!store.isScheduled(l))
    }

    @Test("toggle で反転")
    func toggle() {
        let (store, _) = makeStore()
        let l = listing()
        store.toggle(l)
        #expect(store.isScheduled(l))
        store.toggle(l)
        #expect(!store.isScheduled(l))
    }

    @Test("複数物件を独立に管理")
    func multipleIndependent() {
        let (store, _) = makeStore()
        let a = listing()
        let b = listing()
        store.setScheduled(true, for: a)
        #expect(store.isScheduled(a))
        #expect(!store.isScheduled(b))
    }

    @Test("永続化は別インスタンスから読める")
    func persistsAcrossInstances() {
        let suite = "test.inspection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let l = listing()

        let writer = InspectionScheduleStore(defaults: defaults)
        writer.setScheduled(true, for: l)

        let reader = InspectionScheduleStore(defaults: defaults)
        #expect(reader.isScheduled(l))
    }

    @Test("二重 setScheduled(true) は冪等")
    func idempotentSet() {
        let (store, _) = makeStore()
        let l = listing()
        store.setScheduled(true, for: l)
        store.setScheduled(true, for: l)
        #expect(store.scheduledKeys.count == 1)
    }
}
