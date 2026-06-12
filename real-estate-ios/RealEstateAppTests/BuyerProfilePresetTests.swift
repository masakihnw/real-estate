import Testing
import Foundation
@testable import RealEstateApp

/// preset はプレースホルダ既定値であり、実データ（PII・実予算）を含まないことのスモークテスト。
/// 実運用の買い手条件は Supabase `buyer_profiles` が正（リポジトリには実データを入れない）。
@Suite("BuyerProfile preset")
struct BuyerProfilePresetTests {

    @Test("予算シナリオに実データが残っていない（プレースホルダ方針）")
    func presetHasNoBudgetScenarios() {
        let preset = BuyerProfile.preset
        #expect(preset.budgetScenarios.isEmpty)
    }

    @Test("実予算・実勤務地などのPIIが preset に残っていない")
    func presetHasNoPII() {
        let preset = BuyerProfile.preset
        let fields = [
            preset.familyComposition,
            preset.householdIncome,
            preset.selfFunds,
            preset.plannedBorrowing,
            preset.monthlyPaymentLimit,
            preset.workStyle,
            preset.priorities,
            preset.commuteQuality,
        ]
        let piiMarkers = ["1.3億", "1.1億", "1,200万円", "一番町", "虎ノ門", "26.94"]
        for field in fields {
            for marker in piiMarkers {
                #expect(!field.contains(marker),
                        "preset に実データ「\(marker)」が残っている: \(field.prefix(60))")
            }
        }
    }

    @Test("マークダウン出力は空シナリオ時に予算シナリオ節を含まない")
    func markdownOmitsEmptyBudgetScenarios() {
        let md = BuyerProfile.preset.toMarkdownSection()
        #expect(!md.contains("予算シナリオ"))
    }

    @Test("マークダウン出力が生成できる（クラッシュしない・空でない）")
    func markdownRenders() {
        let md = BuyerProfile.preset.toMarkdownSection()
        #expect(!md.isEmpty)
    }
}
