import Testing
import Foundation
@testable import RealEstateApp

@Suite("ComparisonRowBuilder 比較行の構築")
struct ComparisonRowBuilderTests {

    private func makeListing(
        priceMan: Int?,
        areaM2: Double?,
        listingScore: Int? = nil
    ) -> Listing {
        Listing(
            url: "https://x/\(UUID().uuidString)",
            name: "t",
            priceMan: priceMan,
            areaM2: areaM2,
            propertyType: "chuko",
            listingScore: listingScore
        )
    }

    @Test("基本行は常に含まれ、順序は 価格→面積→間取り…（スコアは行でなくヘッダーバッジ）")
    func basicRowsOrder() {
        let a = makeListing(priceMan: 8000, areaM2: 70, listingScore: 80)
        let b = makeListing(priceMan: 9000, areaM2: 60, listingScore: 60)
        let rows = ComparisonRowBuilder.rows(for: [a, b])
        let labels = rows.map(\.label)
        #expect(labels.prefix(3) == ["価格", "面積", "間取り"])
        #expect(!labels.contains("投資スコア"))
        #expect(labels.contains("権利形態"))
        // 各行は2物件分の値を持つ
        #expect(rows.allSatisfy { $0.values.count == 2 })
    }

    @Test("価格は安い方が best（higherIsBetter=false）")
    func priceLowerIsBest() {
        let cheap = makeListing(priceMan: 8000, areaM2: 70)
        let pricey = makeListing(priceMan: 9000, areaM2: 70)
        let rows = ComparisonRowBuilder.rows(for: [cheap, pricey])
        let priceRow = rows.first { $0.label == "価格" }!
        #expect(priceRow.higherIsBetter == false)
        #expect(priceRow.bestIndex == 0)   // cheap
        #expect(priceRow.worstIndex == 1)  // pricey
    }

    @Test("面積は広い方が best（higherIsBetter=true）")
    func areaHigherIsBest() {
        let small = makeListing(priceMan: 8000, areaM2: 60)
        let large = makeListing(priceMan: 8000, areaM2: 80)
        let rows = ComparisonRowBuilder.rows(for: [small, large])
        let areaRow = rows.first { $0.label == "面積" }!
        #expect(areaRow.bestIndex == 1)   // large
    }

    @Test("投資スコアは比較行に含めない（ヘッダーカードのバッジで表示）")
    func scoreNotARow() {
        let a = makeListing(priceMan: 8000, areaM2: 70, listingScore: 85)
        let b = makeListing(priceMan: 9000, areaM2: 70, listingScore: 50)
        let rows = ComparisonRowBuilder.rows(for: [a, b])
        #expect(!rows.contains { $0.label == "投資スコア" })
        #expect(rows.first?.label == "価格")
    }

    @Test("オプション行（儲かる確率・相場・人口）はデータが無ければ出ない")
    func optionalRowsAbsentWithoutData() {
        let a = makeListing(priceMan: 8000, areaM2: 70)
        let b = makeListing(priceMan: 9000, areaM2: 70)
        let labels = ComparisonRowBuilder.rows(for: [a, b]).map(\.label)
        #expect(!labels.contains("儲かる確率"))
        #expect(!labels.contains("成約相場比"))
        #expect(!labels.contains("エリア人口"))
    }

    @Test("ラベルは一意（id 衝突なし）")
    func labelsUnique() {
        let a = makeListing(priceMan: 8000, areaM2: 70, listingScore: 80)
        let b = makeListing(priceMan: 9000, areaM2: 60, listingScore: 60)
        let labels = ComparisonRowBuilder.rows(for: [a, b]).map(\.label)
        #expect(Set(labels).count == labels.count)
    }
}
