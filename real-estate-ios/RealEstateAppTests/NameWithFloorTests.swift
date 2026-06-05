import Testing
@testable import RealEstateApp

@Suite("nameWithFloor")
struct NameWithFloorTests {

    private func makeListing(name: String, floorPosition: Int? = nil) -> Listing {
        Listing(
            url: "https://test.example.com/namefloor_\(UUID().uuidString)",
            name: name,
            floorPosition: floorPosition
        )
    }

    // MARK: - Basic behavior

    @Test("appends floor when floorPosition is present")
    func appendsFloor() {
        let listing = makeListing(name: "パークタワー晴海", floorPosition: 12)
        #expect(listing.nameWithFloor == "パークタワー晴海 12階")
    }

    @Test("returns name as-is when floorPosition is nil")
    func noFloorPosition() {
        let listing = makeListing(name: "パークタワー晴海")
        #expect(listing.nameWithFloor == "パークタワー晴海")
    }

    @Test("floor 1 is displayed correctly")
    func firstFloor() {
        let listing = makeListing(name: "ブリリア有明", floorPosition: 1)
        #expect(listing.nameWithFloor == "ブリリア有明 1階")
    }

    // MARK: - Duplicate prevention

    @Test("does not append when name already contains floor suffix")
    func nameAlreadyHasFloor() {
        let listing = makeListing(name: "パークタワー晴海 12階", floorPosition: 12)
        #expect(listing.nameWithFloor == "パークタワー晴海 12階")
    }

    @Test("does not append when name contains floor mid-string")
    func nameHasFloorMidString() {
        let listing = makeListing(name: "ザ・タワー 5階部分", floorPosition: 5)
        #expect(listing.nameWithFloor == "ザ・タワー 5階部分")
    }

    @Test("does not append when name ends with F notation")
    func nameEndsWithF() {
        let listing = makeListing(name: "ライオンズマンション 9F", floorPosition: 9)
        #expect(listing.nameWithFloor == "ライオンズマンション 9F")
    }

    @Test("does not append when name ends with lowercase f")
    func nameEndsWithLowercaseF() {
        let listing = makeListing(name: "ライオンズマンション 9f", floorPosition: 9)
        #expect(listing.nameWithFloor == "ライオンズマンション 9f")
    }

    // MARK: - Edge cases

    @Test("name containing 階建 without bare 階 still appends floor")
    func nameWithFloorTotalOnly() {
        let listing = makeListing(name: "20階建タワー", floorPosition: 5)
        #expect(listing.nameWithFloor == "20階建タワー 5階")
    }
}
