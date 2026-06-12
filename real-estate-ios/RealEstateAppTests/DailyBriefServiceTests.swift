import Testing
import Foundation
@testable import RealEstateApp

@Suite("DailyBriefService AIデイリーブリーフ")
struct DailyBriefServiceTests {

    // MARK: - parseLatest（PostgREST レスポンスのパース）

    @Test("正常な行配列から先頭ブリーフを取り出す")
    func parsesValidRow() {
        let json = """
        [{"brief_date":"2026-06-12","summary_text":"新着3件。広尾の物件が▼200万。","market_insights":"相場は横ばい"}]
        """.data(using: .utf8)!
        let brief = DailyBriefService.parseLatest(from: json)
        #expect(brief?.briefDate == "2026-06-12")
        #expect(brief?.summaryText == "新着3件。広尾の物件が▼200万。")
        #expect(brief?.marketInsights == "相場は横ばい")
    }

    @Test("空配列は nil")
    func emptyArrayReturnsNil() {
        let json = "[]".data(using: .utf8)!
        #expect(DailyBriefService.parseLatest(from: json) == nil)
    }

    @Test("summary_text が null / 空白のみは nil（フォールバックさせる）")
    func nullOrBlankSummaryReturnsNil() {
        let nullJson = """
        [{"brief_date":"2026-06-12","summary_text":null,"market_insights":null}]
        """.data(using: .utf8)!
        #expect(DailyBriefService.parseLatest(from: nullJson) == nil)

        let blankJson = """
        [{"brief_date":"2026-06-12","summary_text":"  \\n ","market_insights":null}]
        """.data(using: .utf8)!
        #expect(DailyBriefService.parseLatest(from: blankJson) == nil)
    }

    @Test("market_insights 欠落（キーなし）でもパースできる")
    func missingInsightsKeyParses() {
        let json = """
        [{"brief_date":"2026-06-12","summary_text":"今日は動きなし。"}]
        """.data(using: .utf8)!
        let brief = DailyBriefService.parseLatest(from: json)
        #expect(brief?.summaryText == "今日は動きなし。")
        #expect(brief?.marketInsights == nil)
    }

    @Test("不正な JSON は nil")
    func invalidJSONReturnsNil() {
        let json = "{not valid".data(using: .utf8)!
        #expect(DailyBriefService.parseLatest(from: json) == nil)
    }

    // MARK: - isFresh（JST 当日判定）

    private static let jstFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @Test("now と同じ JST 日付なら fresh")
    func sameDayIsFresh() {
        let today = Self.jstFormatter.string(from: Date())
        #expect(DailyBriefService.isFresh(briefDate: today))
    }

    @Test("昨日（JST）のブリーフは stale")
    func yesterdayIsStale() {
        let yesterday = Self.jstFormatter.string(
            from: Date().addingTimeInterval(-24 * 3600)
        )
        #expect(!DailyBriefService.isFresh(briefDate: yesterday))
    }

    @Test("不正な日付文字列は stale 扱い")
    func garbageDateIsStale() {
        #expect(!DailyBriefService.isFresh(briefDate: "not-a-date"))
        #expect(!DailyBriefService.isFresh(briefDate: ""))
    }

    @Test("todayKey は JST の今日を yyyy-MM-dd で返す")
    func todayKeyMatchesJST() {
        // JST 2026-06-12 00:30 (= UTC 2026-06-11 15:30)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 15, minute: 30))!
        #expect(DailyBriefService.todayKey(now: now) == "2026-06-12")
    }

    @Test("JST 日付境界: now を注入して決定的に判定")
    func jstBoundaryDeterministic() {
        // JST 2026-06-12 00:30 (= UTC 2026-06-11 15:30) のとき、
        // brief_date "2026-06-12" は fresh、"2026-06-11" は stale
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 15, minute: 30))!
        #expect(DailyBriefService.isFresh(briefDate: "2026-06-12", now: now))
        #expect(!DailyBriefService.isFresh(briefDate: "2026-06-11", now: now))
    }
}
