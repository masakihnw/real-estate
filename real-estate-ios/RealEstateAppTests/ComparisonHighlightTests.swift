import Testing
@testable import RealEstateApp

@Suite("ComparisonHighlight")
struct ComparisonHighlightTests {

    @Test("higherIsBetter=false（価格など）: 最小が best、最大が worst")
    func lowerIsBetter() {
        let values: [Double?] = [9800, 8500, 9200]
        #expect(ComparisonHighlight.bestIndex(values, higherIsBetter: false) == 1)
        #expect(ComparisonHighlight.worstIndex(values, higherIsBetter: false) == 0)
    }

    @Test("higherIsBetter=true（面積など）: 最大が best")
    func higherIsBetter() {
        let values: [Double?] = [60, 75.5, 70]
        #expect(ComparisonHighlight.bestIndex(values, higherIsBetter: true) == 1)
        #expect(ComparisonHighlight.worstIndex(values, higherIsBetter: true) == 0)
    }

    @Test("nil を含む場合は除外して判定")
    func nilsExcluded() {
        let values: [Double?] = [nil, 8500, 9200]
        #expect(ComparisonHighlight.bestIndex(values, higherIsBetter: false) == 1)
        #expect(ComparisonHighlight.worstIndex(values, higherIsBetter: false) == 2)
    }

    @Test("非nil が1件以下なら強調しない")
    func insufficientValues() {
        #expect(ComparisonHighlight.bestIndex([nil, 8500, nil], higherIsBetter: false) == nil)
        #expect(ComparisonHighlight.bestIndex([], higherIsBetter: false) == nil)
    }

    @Test("全て同値なら強調しない")
    func allEqual() {
        let values: [Double?] = [9000, 9000, 9000]
        #expect(ComparisonHighlight.bestIndex(values, higherIsBetter: false) == nil)
        #expect(ComparisonHighlight.worstIndex(values, higherIsBetter: false) == nil)
    }

    @Test("極値が同値で複数ある場合は強調しない（曖昧さ回避）")
    func tiedExtremes() {
        let values: [Double?] = [8500, 8500, 9200]
        #expect(ComparisonHighlight.bestIndex(values, higherIsBetter: false) == nil)
        // worst（9200）は一意なので強調される
        #expect(ComparisonHighlight.worstIndex(values, higherIsBetter: false) == 2)
    }
}
