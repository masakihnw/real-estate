import Testing
import Foundation
@testable import RealEstateApp

@Suite("SupabaseListingStore Timestamp Parser")
struct SupabaseTimestampParserTests {

    @Test("マイクロ秒付き Supabase タイムスタンプをパースできる")
    func parsesFractionalSeconds() {
        let input = "2026-05-18T17:20:52.096894+00:00"
        let date = SupabaseListingStore.parseSupabaseTimestamp(input)
        #expect(date != nil)

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 18)
        #expect(comps.hour == 17)
        #expect(comps.minute == 20)
        #expect(comps.second == 52)
    }

    @Test("秒なし ISO 8601 タイムスタンプをパースできる")
    func parsesWithoutFractional() {
        let input = "2026-05-18T17:20:52+00:00"
        let date = SupabaseListingStore.parseSupabaseTimestamp(input)
        #expect(date != nil)

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(comps.year == 2026)
        #expect(comps.hour == 17)
    }

    @Test("Z サフィックスの UTC タイムスタンプをパースできる")
    func parsesZSuffix() {
        let input = "2026-05-18T17:20:52Z"
        let date = SupabaseListingStore.parseSupabaseTimestamp(input)
        #expect(date != nil)
    }

    @Test("不正な文字列は nil を返す")
    func invalidStringReturnsNil() {
        let date = SupabaseListingStore.parseSupabaseTimestamp("not-a-date")
        #expect(date == nil)
    }

    @Test("空文字列は nil を返す")
    func emptyStringReturnsNil() {
        let date = SupabaseListingStore.parseSupabaseTimestamp("")
        #expect(date == nil)
    }

    @Test("異なるマイクロ秒の2つのタイムスタンプが異なる Date を生成する")
    func differentFractionalSecondsProduceDifferentDates() {
        let date1 = SupabaseListingStore.parseSupabaseTimestamp("2026-05-18T17:20:52.100000+00:00")
        let date2 = SupabaseListingStore.parseSupabaseTimestamp("2026-05-18T17:20:52.900000+00:00")
        #expect(date1 != nil)
        #expect(date2 != nil)
        #expect(date1! < date2!)
    }

    @Test("JST タイムゾーンオフセットをパースできる")
    func parsesJSTOffset() {
        let input = "2026-05-19T02:20:52.000000+09:00"
        let date = SupabaseListingStore.parseSupabaseTimestamp(input)
        #expect(date != nil)

        let utcDate = SupabaseListingStore.parseSupabaseTimestamp("2026-05-18T17:20:52.000000+00:00")
        #expect(utcDate != nil)
        #expect(abs(date!.timeIntervalSince(utcDate!)) < 1)
    }
}
