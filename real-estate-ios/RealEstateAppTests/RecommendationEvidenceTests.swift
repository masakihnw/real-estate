import Testing
import Foundation
@testable import RealEstateApp

@Suite("RecommendationEvidence")
struct RecommendationEvidenceTests {

    private func makeListing(
        flags: [String] = [],
        walkMin: Int? = nil,
        stationLine: String? = nil,
        builtYear: Int? = nil,
        areaM2: Double? = nil,
        layout: String? = nil,
        totalUnits: Int? = nil,
        managementFee: Int? = nil
    ) -> Listing {
        let flagsJSON: String? = flags.isEmpty ? nil : {
            let items = flags.map { "\"\($0)\"" }.joined(separator: ",")
            return "[\(items)]"
        }()
        return Listing(
            source: "test",
            url: "https://example.com/\(UUID().uuidString)",
            name: "テスト物件",
            stationLine: stationLine,
            walkMin: walkMin,
            areaM2: areaM2,
            layout: layout,
            builtYear: builtYear,
            totalUnits: totalUnits,
            managementFee: managementFee,
            aiRecommendationFlagsJSON: flagsJSON
        )
    }

    @Test("駅系フラグは徒歩分数を根拠にする")
    func stationFlag() {
        let listing = makeListing(
            walkMin: 6,
            stationLine: "東京メトロ半蔵門線「住吉」徒歩6分"
        )
        let evidence = RecommendationEvidence.evidence(for: "駅近◎", listing: listing)
        #expect(evidence?.contains("徒歩6分") == true)
    }

    @Test("駅系フラグでもデータがなければ nil")
    func stationFlagWithoutData() {
        let listing = makeListing()
        #expect(RecommendationEvidence.evidence(for: "駅近◎", listing: listing) == nil)
    }

    @Test("築年系フラグ")
    func builtYearFlag() {
        let listing = makeListing(builtYear: 2019)
        let evidence = RecommendationEvidence.evidence(for: "築浅◎", listing: listing)
        #expect(evidence?.contains("2019年築") == true)
    }

    @Test("面積系フラグ")
    func areaFlag() {
        let listing = makeListing(areaM2: 70.5, layout: "3LDK")
        let evidence = RecommendationEvidence.evidence(for: "広さ十分", listing: listing)
        #expect(evidence?.contains("3LDK") == true)
    }

    @Test("管理系フラグ")
    func managementFlag() {
        let listing = makeListing(managementFee: 15000)
        let evidence = RecommendationEvidence.evidence(for: "管理良好", listing: listing)
        #expect(evidence?.contains("管理費") == true)
    }

    @Test("未知カテゴリのフラグは nil")
    func unknownFlag() {
        let listing = makeListing(walkMin: 5)
        #expect(RecommendationEvidence.evidence(for: "謎のフラグ", listing: listing) == nil)
    }

    @Test("evidenceList は根拠が取れたフラグだけ返す")
    func evidenceListFiltersUnresolvable() {
        let listing = makeListing(
            flags: ["駅近◎", "謎のフラグ", "築浅"],
            walkMin: 5,
            stationLine: "山手線「目黒」徒歩5分",
            builtYear: 2020
        )
        let list = RecommendationEvidence.evidenceList(for: listing)
        #expect(list.map(\.flag) == ["駅近◎", "築浅"])
    }
}
