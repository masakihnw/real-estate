import Foundation
import WidgetKit

enum WidgetDataProvider {
    private static let suiteName = "group.com.hanawa.realestate"
    private static let dataKey = "widgetData"

    static func update(
        totalListings: Int,
        newListings: Int,
        likedCount: Int,
        priceChanges: Int,
        likedSummaries: [(name: String, priceMan: Int?, priceChange: Int?)]
    ) {
        struct LikedSummary: Codable {
            let name: String
            let priceMan: Int?
            let priceChange: Int?
        }

        struct Data: Codable {
            let totalListings: Int
            let newListings: Int
            let likedCount: Int
            let lastUpdated: Date
            let priceChanges: Int
            let likedSummaries: [LikedSummary]
        }

        let data = Data(
            totalListings: totalListings,
            newListings: newListings,
            likedCount: likedCount,
            lastUpdated: .now,
            priceChanges: priceChanges,
            likedSummaries: likedSummaries.map { LikedSummary(name: $0.name, priceMan: $0.priceMan, priceChange: $0.priceChange) }
        )

        guard let defaults = UserDefaults(suiteName: suiteName),
              let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: dataKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
