import Testing
import Foundation
@testable import RealEstateApp

@Suite("GradeVisibility 発見導線のグレード表示可否")
struct GradeVisibilityTests {

    private nonisolated(unsafe) static var counter = 0

    private func makeListing(
        assetGrade: String? = nil,
        listingScore: Int? = nil,
        isLiked: Bool = false
    ) -> Listing {
        GradeVisibilityTests.counter += 1
        let unique = "grade_\(GradeVisibilityTests.counter)_\(UUID().uuidString.prefix(8))"
        return Listing(
            url: "https://test.example.com/\(unique)",
            name: unique,
            isLiked: isLiked,
            propertyType: "chuko",
            listingScore: listingScore,
            assetGrade: assetGrade
        )
    }

    @Test("D評価は非表示")
    func hidesGradeD() {
        #expect(GradeVisibility.isVisible(makeListing(assetGrade: "D")) == false)
    }

    @Test("S/A/B/C は表示", arguments: ["S", "A", "B", "C"])
    func showsNonHiddenGrades(grade: String) {
        #expect(GradeVisibility.isVisible(makeListing(assetGrade: grade)) == true)
    }

    @Test("グレード未付与（未分析・スコアも無し）は表示する（フェイルセーフ）")
    func showsUngraded() {
        #expect(GradeVisibility.isVisible(makeListing()) == true)
    }

    @Test("小文字 d でも非表示（大文字正規化）")
    func hidesLowercaseGradeD() {
        #expect(GradeVisibility.isVisible(makeListing(assetGrade: "d")) == false)
    }

    @Test("いいね済みなら D 評価でも表示する")
    func showsLikedEvenIfGradeD() {
        #expect(GradeVisibility.isVisible(makeListing(assetGrade: "D", isLiked: true)) == true)
    }

    @Test("assetGrade が無くても listingScore からの算出グレードが D なら非表示")
    func hidesComputedGradeD() {
        // gradeThresholds: c=35 未満が D
        let listing = makeListing(listingScore: 10)
        #expect(listing.scoreGradeLetter == "D")
        #expect(GradeVisibility.isVisible(listing) == false)
    }

    @Test("assetGrade が無く listingScore が高ければ表示")
    func showsComputedHighGrade() {
        let listing = makeListing(listingScore: 90)
        #expect(GradeVisibility.isVisible(listing) == true)
    }

    @Test("visible は D を除外し順序を保持する")
    func visibleFiltersAndPreservesOrder() {
        let a = makeListing(assetGrade: "A")
        let d = makeListing(assetGrade: "D")
        let b = makeListing(assetGrade: "B")
        let result = GradeVisibility.visible([a, d, b])
        #expect(result.map(\.identityKey) == [a.identityKey, b.identityKey])
    }

    @Test("空配列はそのまま空")
    func visibleEmpty() {
        #expect(GradeVisibility.visible([]).isEmpty)
    }
}
