import Testing
import Foundation
@testable import RealEstateApp

@Suite("ListingNumericField データ充足率")
struct NumericFieldFillRateTests {

    private func listing(totalUnits: Int?) -> Listing {
        Listing(url: "https://x/\(UUID().uuidString)", name: "t", propertyType: "chuko", totalUnits: totalUnits)
    }

    @Test("全件データありは 1.0")
    func allFilled() {
        let listings = [listing(totalUnits: 100), listing(totalUnits: 50)]
        #expect(ListingNumericField.totalUnits.fillRate(in: listings) == 1.0)
    }

    @Test("半数データありは 0.5")
    func halfFilled() {
        let listings = [listing(totalUnits: 100), listing(totalUnits: nil)]
        #expect(ListingNumericField.totalUnits.fillRate(in: listings) == 0.5)
    }

    @Test("全件 nil は 0.0")
    func noneFilled() {
        let listings = [listing(totalUnits: nil), listing(totalUnits: nil)]
        #expect(ListingNumericField.totalUnits.fillRate(in: listings) == 0.0)
    }

    @Test("空配列は 0.0（ゼロ除算しない）")
    func emptyIsZero() {
        #expect(ListingNumericField.totalUnits.fillRate(in: []) == 0.0)
    }
}
