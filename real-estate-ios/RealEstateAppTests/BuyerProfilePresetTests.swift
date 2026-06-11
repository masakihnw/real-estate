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

    @Test("古い試算例（26.94万）が残っていない")
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
        #expect(md.contains("1.3億"))
    }
}
