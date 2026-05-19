import Testing
import Foundation
@testable import RealEstateApp

@Suite("ListingFilter.availableRouteStations")
struct ListingFilterRouteStationsTests {

    private func makeListing(stationLine: String?) -> Listing {
        Listing(url: "https://example.com/\(UUID().uuidString)", name: "テスト物件", stationLine: stationLine)
    }

    @Test("空のリストから空の結果を返す")
    func emptyListings() {
        let result = ListingFilter.availableRouteStations(from: [])
        #expect(result.isEmpty)
    }

    @Test("stationLine が nil の物件のみ → 空の結果")
    func allNilStationLines() {
        let listings = [makeListing(stationLine: nil), makeListing(stationLine: nil)]
        let result = ListingFilter.availableRouteStations(from: listings)
        #expect(result.isEmpty)
    }

    @Test("路線名でグルーピングされる")
    func groupsByRoute() {
        let listings = [
            makeListing(stationLine: "東京メトロ半蔵門線「半蔵門」徒歩5分"),
            makeListing(stationLine: "東京メトロ半蔵門線「表参道」徒歩3分"),
            makeListing(stationLine: "ＪＲ山手線「渋谷」徒歩10分"),
        ]
        let result = ListingFilter.availableRouteStations(from: listings)

        let routeNames = result.map(\.routeName)
        #expect(routeNames.contains("東京メトロ半蔵門線"))
        #expect(routeNames.contains("ＪＲ山手線"))
    }

    @Test("同一路線の駅名が重複しない")
    func noDuplicateStationsInRoute() {
        let listings = [
            makeListing(stationLine: "東京メトロ半蔵門線「半蔵門」徒歩5分"),
            makeListing(stationLine: "東京メトロ半蔵門線「半蔵門」徒歩8分"),
            makeListing(stationLine: "東京メトロ半蔵門線「表参道」徒歩3分"),
        ]
        let result = ListingFilter.availableRouteStations(from: listings)

        if let hanzomon = result.first(where: { $0.routeName == "東京メトロ半蔵門線" }) {
            #expect(hanzomon.stationNames.count == 2)
            #expect(hanzomon.stationNames.contains("半蔵門"))
            #expect(hanzomon.stationNames.contains("表参道"))
        } else {
            Issue.record("半蔵門線が結果に含まれていない")
        }
    }
}
