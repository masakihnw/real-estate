import Testing
import Foundation
@testable import RealEstateApp

@Suite("AIRecommendationStyle")
struct AIRecommendationStyleTests {

    // MARK: - label(forScore:)

    @Test("スコアに対応するラベルを返す", arguments: [
        (5, "強く推奨"),
        (4, "推奨"),
        (3, "条件次第"),
        (2, "非推奨"),
        (1, "見送り"),
    ])
    func labelForScore(score: Int, expected: String) {
        #expect(AIRecommendationStyle.label(forScore: score) == expected)
    }

    @Test("範囲外・nil のスコアは空文字")
    func labelForInvalidScore() {
        #expect(AIRecommendationStyle.label(forScore: nil) == "")
        #expect(AIRecommendationStyle.label(forScore: 0) == "")
        #expect(AIRecommendationStyle.label(forScore: 6) == "")
    }

    // MARK: - sentiment(forFlag:)

    @Test("否定キーワードを含むフラグは negative")
    func negativeFlags() {
        #expect(AIRecommendationStyle.sentiment(forFlag: "定借リスク（残存54年→44年）") == .negative)
        #expect(AIRecommendationStyle.sentiment(forFlag: "予算NG") == .negative)
        #expect(AIRecommendationStyle.sentiment(forFlag: "面積不足") == .negative)
    }

    @Test("注意キーワードを含むフラグは caution")
    func cautionFlags() {
        #expect(AIRecommendationStyle.sentiment(forFlag: "管理状況に注意") == .caution)
        #expect(AIRecommendationStyle.sentiment(forFlag: "権利形態が不透明") == .caution)
    }

    @Test("◎/○ で終わるフラグは positive")
    func positiveFlags() {
        #expect(AIRecommendationStyle.sentiment(forFlag: "所有権◎") == .positive)
        #expect(AIRecommendationStyle.sentiment(forFlag: "通勤20分以内○") == .positive)
    }

    @Test("否定キーワードは肯定マーカーより優先される")
    func negativePrecedesPositive() {
        // ◎ を含むが「リスク」も含む → negative 優先
        #expect(AIRecommendationStyle.sentiment(forFlag: "立地◎だが定借リスク") == .negative)
    }

    @Test("いずれにも該当しないフラグは neutral")
    func neutralFlags() {
        #expect(AIRecommendationStyle.sentiment(forFlag: "築23年") == .neutral)
        #expect(AIRecommendationStyle.sentiment(forFlag: "ペット可") == .neutral)
    }
}
