import Testing
import Foundation
@testable import RealEstateApp

/// preset の買い手条件が MTG（2026/6/8）方針を反映しているかのスモークテスト。
/// 正準ソースは scraping-tool/config/buyer_profile.json（手動同期）。
@Suite("BuyerProfile preset")
struct BuyerProfilePresetTests {

    @Test("予算シナリオ（二段構え）が設定されている")
    func presetHasBudgetScenarios() {
        let preset = BuyerProfile.preset
        #expect(!preset.budgetScenarios.isEmpty)
        let labels = preset.budgetScenarios.compactMap { $0["label"] }
        #expect(labels.contains("探索上限"))
        #expect(labels.contains("実質アンカー"))
    }

    @Test("古い試算例（（金額））が残っていない")
    func presetHasNoStaleExample() {
        let preset = BuyerProfile.preset
        #expect(!preset.plannedBorrowing.contains("26.94"))
        #expect(!preset.monthlyPaymentLimit.contains("26.94"))
    }

    @Test("マークダウン出力に予算シナリオが含まれる")
    func markdownRendersBudgetScenarios() {
        let md = BuyerProfile.preset.toMarkdownSection()
        #expect(md.contains("予算シナリオ"))
        #expect(md.contains("探索上限"))
        #expect(md.contains("実質アンカー"))
    }

    @Test("preset に買い手の実予算（家計PII）が含まれない")
    func presetHasNoRealBudgetPII() {
        // 公開リポジトリのため preset はプレースホルダのみ。実額は Supabase が正。
        let md = BuyerProfile.preset.toMarkdownSection()
        for leaked in ["1.3億", "1.1億", "1,200万", "30万円"] {
            #expect(!md.contains(leaked))
        }
    }

    // MARK: - エクスポート注入ヘルパー

    @Test("budgetCriteriaInline は予算シナリオの値を注入する")
    func budgetCriteriaInjectsScenarioValues() {
        // 注入機構の検証なので実PIIではなく合成値を使う（公開リポジトリ対策）
        var profile = BuyerProfile.empty
        profile.budgetScenarios = [
            ["label": "探索上限", "value": "9.9億円"],
            ["label": "実質アンカー", "value": "8.8億円前後"],
        ]
        let line = profile.budgetCriteriaInline()
        #expect(line.contains("探索上限 9.9億円"))
        #expect(line.contains("実質アンカー 8.8億円前後"))
    }

    @Test("budgetCriteriaInline はシナリオ未設定時に汎用文言へフォールバック")
    func budgetCriteriaFallsBackWhenEmpty() {
        let line = BuyerProfile.empty.budgetCriteriaInline()
        #expect(line.contains("買い手プロフィール参照"))
        // 実額をハードコードしていないこと
        for leaked in ["1.3億", "1.1億", "30万"] { #expect(!line.contains(leaked)) }
    }

    @Test("monthlyLimitInline は月額上限を注入し、未設定時はフォールバック")
    func monthlyLimitInjectsAndFallsBack() {
        var profile = BuyerProfile.empty
        profile.monthlyPaymentLimit = "ローン返済99万円/月以内"
        #expect(profile.monthlyLimitInline() == "ローン返済99万円/月以内")
        #expect(BuyerProfile.empty.monthlyLimitInline() == "予算シナリオの月返済上限")
    }

    @Test("preset（プレースホルダ）の注入結果に実PIIが出ない")
    func presetInjectionHasNoPII() {
        let line = BuyerProfile.preset.budgetCriteriaInline()
        for leaked in ["1.3億", "1.1億", "1,200万", "30万円"] {
            #expect(!line.contains(leaked))
        }
    }
}
