import Testing
import Foundation
@testable import RealEstateApp

@Suite("PreferenceAnalyzer 重複排除")
struct PreferenceAnalyzerDedupTests {

    // MARK: - Helpers

    private func makeListing(
        id: Int,
        name: String = "テスト物件",
        normalizedName: String? = nil,
        priceMan: Int = 10000,
        areaM2: Double = 70.0,
        walkMin: Int = 5,
        builtYear: Int = 2010,
        layout: String = "3LDK",
        address: String = "東京都江東区豊洲1-1",
        floorPosition: Int = 5,
        totalUnits: Int = 100
    ) -> Listing {
        Listing(
            source: "test",
            url: "https://example.com/\(id)",
            name: name,
            priceMan: priceMan,
            address: address,
            walkMin: walkMin,
            areaM2: areaM2,
            layout: layout,
            builtYear: builtYear,
            totalUnits: totalUnits,
            floorPosition: floorPosition,
            normalizedName: normalizedName
        )
    }

    private func makeLikedListings(count: Int, startId: Int = 1000) -> [Listing] {
        (0..<count).map { i in
            makeListing(
                id: startId + i,
                name: "お気に入り物件\(i)",
                normalizedName: "お気に入りマンション\(i)",
                priceMan: 9000 + i * 100,
                areaM2: 65.0 + Double(i),
                walkMin: 3 + (i % 5),
                builtYear: 2015 - (i % 10),
                address: "東京都江東区豊洲\(i + 1)-\(i + 1)"
            )
        }
    }

    private func makeNopedListings(count: Int, startId: Int = 2000) -> [Listing] {
        (0..<count).map { i in
            makeListing(
                id: startId + i,
                name: "Nope物件\(i)",
                normalizedName: "Nopeマンション\(i)",
                priceMan: 15000 + i * 200,
                areaM2: 40.0 + Double(i),
                walkMin: 15 + (i % 5),
                builtYear: 1990 - (i % 10),
                layout: "2LDK",
                address: "東京都足立区\(i + 1)-\(i + 1)"
            )
        }
    }

    private func runAnalyzer(candidates: [Listing]) -> PreferenceProfile {
        let liked = makeLikedListings(count: 25)
        let noped = makeNopedListings(count: 25)
        let allListings = liked + noped + candidates

        let likedKeys = Set(liked.map(\.identityKey))
        let nopedKeys = Set(noped.map(\.identityKey))

        return PreferenceAnalyzer.analyze(
            allListings: allListings,
            likedKeys: likedKeys,
            nopedKeys: nopedKeys
        )
    }

    // MARK: - Tests

    @Test("同一 normalizedName の物件は最高スコアの1件のみ表示される")
    func deduplicatesSameBuilding() {
        let candidates = [
            makeListing(id: 1, name: "バウス久我山 101", normalizedName: "バウス久我山",
                        priceMan: 10000, areaM2: 70.0, address: "東京都杉並区久我山1-1"),
            makeListing(id: 2, name: "バウス久我山 502", normalizedName: "バウス久我山",
                        priceMan: 10500, areaM2: 71.0, address: "東京都杉並区久我山1-1"),
            makeListing(id: 3, name: "バウス久我山 803", normalizedName: "バウス久我山",
                        priceMan: 11000, areaM2: 72.0, address: "東京都杉並区久我山1-1"),
        ]

        let profile = runAnalyzer(candidates: candidates)
        let matchingRecs = profile.recommendations.filter {
            $0.listing.normalizedName == "バウス久我山"
        }
        #expect(matchingRecs.count == 1)
    }

    @Test("normalizedName が nil の物件はそれぞれ個別に扱われる")
    func nilNormalizedNameTreatedAsUnique() {
        let candidates = [
            makeListing(id: 1, name: "物件A", normalizedName: nil,
                        priceMan: 10000, areaM2: 70.0, address: "東京都江東区豊洲1-1"),
            makeListing(id: 2, name: "物件B", normalizedName: nil,
                        priceMan: 10100, areaM2: 71.0, address: "東京都江東区豊洲2-2"),
        ]

        let profile = runAnalyzer(candidates: candidates)
        let nilNameRecs = profile.recommendations.filter { $0.listing.normalizedName == nil }
        #expect(nilNameRecs.count == 2)
    }

    @Test("normalizedName が空文字の物件はそれぞれ個別に扱われる")
    func emptyNormalizedNameTreatedAsUnique() {
        let candidates = [
            makeListing(id: 1, name: "物件A", normalizedName: "",
                        priceMan: 10000, areaM2: 70.0, address: "東京都江東区豊洲1-1"),
            makeListing(id: 2, name: "物件B", normalizedName: "",
                        priceMan: 10100, areaM2: 71.0, address: "東京都江東区豊洲2-2"),
        ]

        let profile = runAnalyzer(candidates: candidates)
        let emptyNameRecs = profile.recommendations.filter { $0.listing.normalizedName == "" }
        #expect(emptyNameRecs.count == 2)
    }

    @Test("異なる normalizedName の物件はそれぞれ表示される")
    func differentBuildingsAllShown() {
        let candidates = [
            makeListing(id: 1, name: "マンションA 101", normalizedName: "マンションA",
                        priceMan: 10000, areaM2: 70.0, address: "東京都江東区豊洲1-1"),
            makeListing(id: 2, name: "マンションB 201", normalizedName: "マンションB",
                        priceMan: 10100, areaM2: 71.0, address: "東京都江東区豊洲2-2"),
            makeListing(id: 3, name: "マンションC 301", normalizedName: "マンションC",
                        priceMan: 10200, areaM2: 72.0, address: "東京都江東区豊洲3-3"),
        ]

        let profile = runAnalyzer(candidates: candidates)
        let buildingNames = Set(profile.recommendations.compactMap(\.listing.normalizedName))
        #expect(buildingNames.count == 3)
        #expect(buildingNames.contains("マンションA"))
        #expect(buildingNames.contains("マンションB"))
        #expect(buildingNames.contains("マンションC"))
    }

    @Test("複数マンションで重複あり + nil 混在のシナリオ")
    func mixedDuplicateAndNilScenario() {
        let candidates = [
            makeListing(id: 1, name: "A棟101", normalizedName: "マンションA",
                        priceMan: 10000, areaM2: 70.0, address: "東京都江東区豊洲1-1"),
            makeListing(id: 2, name: "A棟502", normalizedName: "マンションA",
                        priceMan: 10500, areaM2: 71.0, address: "東京都江東区豊洲1-1"),
            makeListing(id: 3, name: "B棟201", normalizedName: "マンションB",
                        priceMan: 10000, areaM2: 70.0, address: "東京都江東区豊洲2-2"),
            makeListing(id: 4, name: "B棟301", normalizedName: "マンションB",
                        priceMan: 10200, areaM2: 72.0, address: "東京都江東区豊洲2-2"),
            makeListing(id: 5, name: "個別物件", normalizedName: nil,
                        priceMan: 10000, areaM2: 70.0, address: "東京都江東区豊洲3-3"),
        ]

        let profile = runAnalyzer(candidates: candidates)
        let aRecs = profile.recommendations.filter { $0.listing.normalizedName == "マンションA" }
        let bRecs = profile.recommendations.filter { $0.listing.normalizedName == "マンションB" }
        let nilRecs = profile.recommendations.filter { $0.listing.normalizedName == nil }
        #expect(aRecs.count == 1)
        #expect(bRecs.count == 1)
        #expect(nilRecs.count == 1)
    }
}
