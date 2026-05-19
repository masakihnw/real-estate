import Testing
import Foundation
@testable import RealEstateApp

@Suite("CommuteData ダウングレード防止ロジック")
struct CommuteDataDowngradeTests {

    private func makeDestination(minutes: Int, summary: String, source: String? = nil) -> CommuteDestination {
        CommuteDestination(minutes: minutes, summary: summary, transfers: 1, calculatedAt: Date(), source: source)
    }

    private func makeFallbackDestination(minutes: Int) -> CommuteDestination {
        CommuteDestination(minutes: minutes, summary: "経路情報取得不可（直線距離概算）", transfers: nil, calculatedAt: Date(), source: nil)
    }

    /// 実際のプロダクションコードと同じダウングレード判定ロジック
    private func isExistingBetter(existing: CommuteDestination?, newResult: CommuteDestination) -> Bool {
        existing.map { !$0.isFallbackEstimate && newResult.isFallbackEstimate } ?? false
    }

    @Test("既存が正規経路で新結果がフォールバック → 既存を維持（ダウングレード防止）")
    func existingReliableNewFallback_keepsExisting() {
        let existing = makeDestination(minutes: 30, summary: "東京メトロ半蔵門線")
        let newFallback = makeFallbackDestination(minutes: 45)

        #expect(isExistingBetter(existing: existing, newResult: newFallback) == true)
    }

    @Test("既存がフォールバックで新結果が正規経路 → 上書き許可")
    func existingFallbackNewReliable_allowsOverwrite() {
        let existing = makeFallbackDestination(minutes: 45)
        let newReliable = makeDestination(minutes: 30, summary: "東京メトロ半蔵門線")

        #expect(isExistingBetter(existing: existing, newResult: newReliable) == false)
    }

    @Test("既存が nil → 上書き許可")
    func noExisting_allowsOverwrite() {
        let newResult = makeDestination(minutes: 30, summary: "東京メトロ半蔵門線")

        #expect(isExistingBetter(existing: nil, newResult: newResult) == false)
    }

    @Test("両方とも正規経路 → 上書き許可（新しいデータが優先）")
    func bothReliable_allowsOverwrite() {
        let existing = makeDestination(minutes: 30, summary: "東京メトロ半蔵門線")
        let newResult = makeDestination(minutes: 25, summary: "JR山手線")

        #expect(isExistingBetter(existing: existing, newResult: newResult) == false)
    }

    @Test("両方ともフォールバック → 上書き許可")
    func bothFallback_allowsOverwrite() {
        let existing = makeFallbackDestination(minutes: 45)
        let newResult = makeFallbackDestination(minutes: 40)

        #expect(isExistingBetter(existing: existing, newResult: newResult) == false)
    }

    @Test("isFallbackEstimate は summary に '経路情報取得不可' を含む場合 true")
    func fallbackEstimateDetection() {
        let fallback = makeFallbackDestination(minutes: 45)
        let reliable = makeDestination(minutes: 30, summary: "東京メトロ半蔵門線")

        #expect(fallback.isFallbackEstimate == true)
        #expect(reliable.isFallbackEstimate == false)
    }

    @Test("CommuteData の encode/decode ラウンドトリップ")
    func commuteDataRoundTrip() throws {
        var data = CommuteData()
        data.playground = makeDestination(minutes: 25, summary: "半蔵門線", source: "gmaps")
        data.m3career = makeDestination(minutes: 35, summary: "日比谷線", source: "yahoo_transit")

        let json = data.encode()
        #expect(json != nil)

        let decoded = try CommuteData.decoder.decode(CommuteData.self, from: json!.data(using: .utf8)!)
        #expect(decoded.playground?.minutes == 25)
        #expect(decoded.m3career?.minutes == 35)
        #expect(decoded.playground?.source == "gmaps")
        #expect(decoded.m3career?.source == "yahoo_transit")
    }
}
