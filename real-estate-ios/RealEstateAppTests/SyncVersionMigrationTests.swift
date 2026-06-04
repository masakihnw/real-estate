import Testing
import Foundation
@testable import RealEstateApp

@Suite("SyncVersion Migration")
struct SyncVersionMigrationTests {

    private let defaults = UserDefaults.standard
    private let syncVersionKey = "supabase.syncVersion"
    private let lastSyncKeyChuko = "supabase.lastSync.chuko"

    @Test("currentSyncVersion は 2 以上")
    func syncVersionIsAtLeast2() {
        #expect(SupabaseListingStore.currentSyncVersion >= 2)
    }

    @Test("syncVersion が最新ならリセットされない")
    func noResetWhenVersionIsCurrent() {
        let sentinel = "2026-06-04T00:00:00Z"
        defaults.set(SupabaseListingStore.currentSyncVersion, forKey: syncVersionKey)
        defaults.set(sentinel, forKey: lastSyncKeyChuko)
        defer {
            defaults.removeObject(forKey: syncVersionKey)
            defaults.removeObject(forKey: lastSyncKeyChuko)
        }

        SupabaseListingStore.shared.migrateSyncVersionIfNeeded()

        let stored = defaults.string(forKey: lastSyncKeyChuko)
        #expect(stored == sentinel)
    }

    @Test("syncVersion が古い場合、lastSync がクリアされる")
    func resetsWhenVersionIsOutdated() {
        defaults.set(SupabaseListingStore.currentSyncVersion - 1, forKey: syncVersionKey)
        defaults.set("2026-01-01T00:00:00Z", forKey: lastSyncKeyChuko)
        defer {
            defaults.removeObject(forKey: syncVersionKey)
            defaults.removeObject(forKey: lastSyncKeyChuko)
        }

        SupabaseListingStore.shared.migrateSyncVersionIfNeeded()

        let stored = defaults.string(forKey: lastSyncKeyChuko)
        #expect(stored == nil)
        #expect(defaults.integer(forKey: syncVersionKey) == SupabaseListingStore.currentSyncVersion)
    }
}
