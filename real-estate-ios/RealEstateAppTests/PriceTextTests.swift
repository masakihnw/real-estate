import Testing
@testable import RealEstateApp

@Suite("PriceText Formatting")
struct PriceTextTests {

    // MARK: - PriceText.format（万円付き）

    @Test("9,800万円")
    func format9800() {
        #expect(PriceText.format(9_800) == "9,800万円")
    }

    @Test("1万円ちょうど（最小値）")
    func format1() {
        #expect(PriceText.format(1) == "1万円")
    }

    @Test("9,999万円（億未満の最大値）")
    func format9999() {
        #expect(PriceText.format(9_999) == "9,999万円")
    }

    @Test("1億ちょうど → 端数なしは「1億」（万円なし）")
    func format1Oku() {
        #expect(PriceText.format(10_000) == "1億")
    }

    @Test("1億2,300万円")
    func format12300() {
        #expect(PriceText.format(12_300) == "1億2,300万円")
    }

    @Test("2億ちょうど")
    func format2Oku() {
        #expect(PriceText.format(20_000) == "2億")
    }

    @Test("11億4,000万円（大型物件）")
    func formatLarge() {
        #expect(PriceText.format(114_000) == "11億4,000万円")
    }

    // MARK: - PriceText.formatShort（万のみ）

    @Test("9,800万")
    func formatShort9800() {
        #expect(PriceText.formatShort(9_800) == "9,800万")
    }

    @Test("1億ちょうど → 「1億」（万なし）")
    func formatShort1Oku() {
        #expect(PriceText.formatShort(10_000) == "1億")
    }

    @Test("1億2,300万")
    func formatShort12300() {
        #expect(PriceText.formatShort(12_300) == "1億2,300万")
    }

    @Test("5,000万")
    func formatShort5000() {
        #expect(PriceText.formatShort(5_000) == "5,000万")
    }

    // MARK: - Listing.formatPriceCompact との互換性

    @Test("PriceText.format() は Listing.formatPriceCompact() と同一結果")
    func compatibleWithListingFormatPriceCompact() {
        let prices = [1, 5_000, 9_800, 9_999, 10_000, 12_300, 20_000, 114_000]
        for price in prices {
            let expected = Listing.formatPriceCompact(price)
            let actual   = PriceText.format(price)
            #expect(expected == actual,
                    "price=\(price): Listing=\(expected), PriceText=\(actual)")
        }
    }

    // MARK: - DeltaBadge との組み合わせ確認用（パーセント計算）

    @Test("値下がり 200万 / 基準 12,500万 → 1.6%")
    func deltaBadgePercent() {
        let deltaMan = -200
        let baseMan  = 12_500
        let pct = abs(Double(deltaMan) / Double(baseMan) * 100)
        #expect(abs(pct - 1.6) < 0.01)
    }

    @Test("値上がり 120万 / 基準 9,480万 → 約1.27%")
    func deltaBadgeUpPercent() {
        let deltaMan = 120
        let baseMan  = 9_480
        let pct = abs(Double(deltaMan) / Double(baseMan) * 100)
        #expect(pct > 1.0 && pct < 2.0)
    }
}
