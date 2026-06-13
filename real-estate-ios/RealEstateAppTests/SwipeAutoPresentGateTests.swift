import Testing
import Foundation
@testable import RealEstateApp

@Suite("SwipeAutoPresentGate")
struct SwipeAutoPresentGateTests {

    // MARK: - shouldPresent

    @Test("対象があり当日未表示なら表示する")
    func presentsWhenPendingAndNotShownToday() {
        #expect(SwipeAutoPresentGate.shouldPresent(
            pendingCount: 164, lastPresentedDay: "2026-6-12", today: "2026-6-13"
        ))
    }

    @Test("当日すでに自動表示済みなら出さない（1日1回まで）")
    func suppressesWhenAlreadyShownToday() {
        #expect(!SwipeAutoPresentGate.shouldPresent(
            pendingCount: 164, lastPresentedDay: "2026-6-13", today: "2026-6-13"
        ))
    }

    @Test("対象が0件なら出さない")
    func suppressesWhenNoPending() {
        #expect(!SwipeAutoPresentGate.shouldPresent(
            pendingCount: 0, lastPresentedDay: "", today: "2026-6-13"
        ))
    }

    @Test("初回（未表示・空文字）でも対象があれば表示する")
    func presentsOnFirstEverLaunch() {
        #expect(SwipeAutoPresentGate.shouldPresent(
            pendingCount: 5, lastPresentedDay: "", today: "2026-6-13"
        ))
    }

    @Test("日付が変われば翌日にまた表示する")
    func presentsAgainOnNextDay() {
        let yesterday = "2026-6-13"
        // 同日は抑制
        #expect(!SwipeAutoPresentGate.shouldPresent(
            pendingCount: 10, lastPresentedDay: yesterday, today: yesterday
        ))
        // 翌日は再表示
        #expect(SwipeAutoPresentGate.shouldPresent(
            pendingCount: 10, lastPresentedDay: yesterday, today: "2026-6-14"
        ))
    }

    // MARK: - dayKey

    @Test("dayKey は同一暦日で安定し、別日では異なる")
    func dayKeyStableWithinDayDistinctAcrossDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let morning = DateComponents(calendar: cal, year: 2026, month: 6, day: 13, hour: 1).date!
        let night = DateComponents(calendar: cal, year: 2026, month: 6, day: 13, hour: 23).date!
        let nextDay = DateComponents(calendar: cal, year: 2026, month: 6, day: 14, hour: 1).date!

        #expect(SwipeAutoPresentGate.dayKey(morning, calendar: cal)
                == SwipeAutoPresentGate.dayKey(night, calendar: cal))
        #expect(SwipeAutoPresentGate.dayKey(morning, calendar: cal)
                != SwipeAutoPresentGate.dayKey(nextDay, calendar: cal))
    }

    @Test("和暦カレンダーでも西暦カレンダーと同一の日キーになる（端末設定変更耐性）")
    func dayKeyIsCalendarIdentifierAgnostic() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = tz
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = tz
        let date = DateComponents(calendar: gregorian, year: 2026, month: 6, day: 13, hour: 12).date!

        #expect(SwipeAutoPresentGate.dayKey(date, calendar: gregorian)
                == SwipeAutoPresentGate.dayKey(date, calendar: japanese),
                "和暦端末でも内部はグレゴリオ暦で組み立てるため一致するべき")
    }

    @Test("年またぎ（JST大晦日深夜）は翌年の日キーになる")
    func dayKeyHandlesYearBoundary() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let dec31 = DateComponents(calendar: cal, year: 2026, month: 12, day: 31, hour: 23, minute: 59).date!
        let jan1 = DateComponents(calendar: cal, year: 2027, month: 1, day: 1, hour: 0, minute: 1).date!

        #expect(SwipeAutoPresentGate.dayKey(dec31, calendar: cal) == "2026-12-31")
        #expect(SwipeAutoPresentGate.dayKey(jan1, calendar: cal) == "2027-1-1")
        #expect(SwipeAutoPresentGate.dayKey(dec31, calendar: cal)
                != SwipeAutoPresentGate.dayKey(jan1, calendar: cal))
    }
}
