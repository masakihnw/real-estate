import Testing
import Foundation
@testable import RealEstateApp

// MARK: - SidebarItem（4タブ構成）

@Suite("SidebarItem 4タブ構成")
struct SidebarItemTests {

    @Test("4ケースのみ（today/browse/favorites/settings）")
    func fourCases() {
        #expect(SidebarItem.allCases.count == 4)
        #expect(Set(SidebarItem.allCases) == Set([.today, .browse, .favorites, .settings]))
    }

    @Test("tabIndex は 0...3 の連番で重複なし")
    func tabIndexContiguous() {
        let indices = SidebarItem.allCases.map(\.tabIndex).sorted()
        #expect(indices == [0, 1, 2, 3])
    }

    @Test("tabIndex → SidebarItem → tabIndex の往復が一致")
    func tabIndexRoundTrip() {
        for item in SidebarItem.allCases {
            let restored = SidebarItem(tabIndex: item.tabIndex)
            #expect(restored == item, "\(item) の往復が不一致")
        }
    }

    @Test("旧6タブ構成の index 4, 5 は nil（救済はContentView側のクランプで実施）")
    func staleTabIndicesReturnNil() {
        #expect(SidebarItem(tabIndex: 4) == nil)
        #expect(SidebarItem(tabIndex: 5) == nil)
        #expect(SidebarItem(tabIndex: -1) == nil)
    }

    @Test("旧 rawValue（dashboard 等）は init?(rawValue:) で nil → フォールバック可能")
    func staleRawValuesReturnNil() {
        for old in ["dashboard", "listings", "map", "transactions"] {
            #expect(SidebarItem(rawValue: old) == nil, "旧値 \(old) が解釈されてしまう")
        }
    }

    @Test("プッシュ通知の tab:0 は「今日」に対応")
    func pushNotificationTabZero() {
        #expect(SidebarItem(tabIndex: 0) == .today)
    }
}

// MARK: - SupabaseClient クエリエンコード

@Suite("SupabaseClient.encodeQueryValue")
struct SupabaseQueryEncodingTests {

    @Test("日本語・空白・記号を含む identityKey が URL 安全になる")
    func encodesUnsafeCharacters() {
        let raw = #"パークハウス 広尾#2|2LDK|82.5|東京都渋谷区&広尾4|1988"#
        let encoded = SupabaseClient.encodeQueryValue(raw)
        // エンコード結果を含む URL が生成できること（旧実装では nil になっていた）
        let url = URL(string: "https://example.supabase.co/rest/v1/t?identity_key=eq.\(encoded)")
        #expect(url != nil)
        // 区切り・フラグメント・パラメータ境界の文字が残っていないこと
        #expect(!encoded.contains("#"))
        #expect(!encoded.contains("&"))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains(" "))
    }

    @Test("ASCII 英数字はそのまま")
    func passesThroughSafeCharacters() {
        #expect(SupabaseClient.encodeQueryValue("abc123") == "abc123")
    }

    @Test("PostgREST の in 句構文（丸括弧・カンマ）は保持、ダブルクオートは %22 化")
    func keepsPostgRESTSyntaxCharacters() {
        let encoded = SupabaseClient.encodeQueryValue(#"in.("a","b")"#)
        // 丸括弧・カンマは urlQueryAllowed に含まれ、そのまま残る
        #expect(encoded.contains("("))
        #expect(encoded.contains(","))
        // ダブルクオートは %22 にエンコードされる（サーバー側でデコードされ in 句として機能する）
        #expect(encoded.contains("%22"))
        #expect(!encoded.contains("\""))
    }
}

// MARK: - DeveloperModeUnlock

@Suite("DeveloperModeUnlock 7タップ解錠")
struct DeveloperModeUnlockTests {

    @Test("7回連続タップで解錠")
    func unlocksAtSevenTaps() {
        var unlock = DeveloperModeUnlock()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<6 {
            let unlocked = unlock.register(now: base.addingTimeInterval(Double(i) * 0.3))
            #expect(!unlocked, "\(i + 1)回目で解錠されてしまった")
        }
        let unlockedAtSeven = unlock.register(now: base.addingTimeInterval(1.8))
        #expect(unlockedAtSeven)
    }

    @Test("6回では解錠しない")
    func doesNotUnlockAtSixTaps() {
        var unlock = DeveloperModeUnlock()
        let base = Date(timeIntervalSince1970: 1_000_000)
        var unlocked = false
        for i in 0..<6 {
            unlocked = unlock.register(now: base.addingTimeInterval(Double(i) * 0.1))
        }
        #expect(!unlocked)
        #expect(unlock.remainingTaps == 1)
    }

    @Test("タップ間隔がタイムアウトを超えるとリセット")
    func resetsAfterTimeout() {
        var unlock = DeveloperModeUnlock(tapsRequired: 3, timeout: 2.0)
        let base = Date(timeIntervalSince1970: 1_000_000)
        _ = unlock.register(now: base)
        _ = unlock.register(now: base.addingTimeInterval(0.5))
        // 2秒超の間隔 → リセットされ、このタップが1回目になる
        let unlocked = unlock.register(now: base.addingTimeInterval(3.0))
        #expect(!unlocked)
        #expect(unlock.count == 1)
    }

    @Test("解錠後はカウンタがリセットされる")
    func resetsAfterUnlock() {
        var unlock = DeveloperModeUnlock(tapsRequired: 2, timeout: 2.0)
        let base = Date(timeIntervalSince1970: 1_000_000)
        _ = unlock.register(now: base)
        let unlockedAtTwo = unlock.register(now: base.addingTimeInterval(0.1))
        #expect(unlockedAtTwo)
        #expect(unlock.count == 0)
        #expect(unlock.remainingTaps == 2)
    }

    @Test("タイムアウト境界ちょうどはリセットされない")
    func boundaryExactlyAtTimeoutDoesNotReset() {
        var unlock = DeveloperModeUnlock(tapsRequired: 3, timeout: 2.0)
        let base = Date(timeIntervalSince1970: 1_000_000)
        _ = unlock.register(now: base)
        _ = unlock.register(now: base.addingTimeInterval(2.0))  // ちょうど2.0秒 → 継続
        #expect(unlock.count == 2)
    }
}
