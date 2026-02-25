import WidgetKit
import SwiftUI

struct WidgetData: Codable {
    let totalListings: Int
    let newListings: Int
    let likedCount: Int
    let lastUpdated: Date
    let priceChanges: Int
    let likedSummaries: [LikedSummary]

    struct LikedSummary: Codable {
        let name: String
        let priceMan: Int?
        let priceChange: Int?
    }

    static let placeholder = WidgetData(
        totalListings: 0,
        newListings: 0,
        likedCount: 0,
        lastUpdated: .now,
        priceChanges: 0,
        likedSummaries: []
    )
}

struct Provider: TimelineProvider {
    private static let suiteName = "group.com.hanawa.realestate"
    private static let dataKey = "widgetData"

    func placeholder(in context: Context) -> RealEstateEntry {
        RealEstateEntry(date: .now, data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (RealEstateEntry) -> Void) {
        completion(RealEstateEntry(date: .now, data: loadData()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RealEstateEntry>) -> Void) {
        let entry = RealEstateEntry(date: .now, data: loadData())
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadData() -> WidgetData {
        guard let defaults = UserDefaults(suiteName: Self.suiteName),
              let data = defaults.data(forKey: Self.dataKey),
              let decoded = try? JSONDecoder().decode(WidgetData.self, from: data) else {
            return .placeholder
        }
        return decoded
    }
}

struct RealEstateEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

struct RealEstateWidget: Widget {
    let kind = "RealEstateWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            RealEstateWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("物件情報")
        .description("新着物件数と更新情報を表示します")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RealEstateWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: RealEstateEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        default:
            smallWidget
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "building.2")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Spacer()
                Text(entry.data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                if entry.data.newListings > 0 {
                    HStack(spacing: 4) {
                        Text("新着")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(entry.data.newListings)件")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                    }
                }

                HStack(spacing: 4) {
                    Text("全")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(entry.data.totalListings)件")
                        .font(.callout)
                        .fontWeight(.semibold)
                }
            }

            if entry.data.priceChanges > 0 {
                Label("価格変動 \(entry.data.priceChanges)件", systemImage: "arrow.up.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(2)
    }

    private var mediumWidget: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "building.2")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text("物件情報")
                        .font(.headline)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("新着")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(entry.data.newListings)件")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                    }
                    HStack(spacing: 8) {
                        Label("\(entry.data.totalListings)件", systemImage: "house")
                        Label("\(entry.data.likedCount)件", systemImage: "heart.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(entry.data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("いいね物件")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if entry.data.likedSummaries.isEmpty {
                    Text("いいね物件がありません")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxHeight: .infinity)
                } else {
                    ForEach(0..<min(3, entry.data.likedSummaries.count), id: \.self) { i in
                        let item = entry.data.likedSummaries[i]
                        HStack {
                            Text(item.name)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer()
                            if let change = item.priceChange, change != 0 {
                                Text("\(change > 0 ? "+" : "")\(change)万")
                                    .font(.caption2)
                                    .foregroundStyle(change < 0 ? .green : .red)
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(2)
    }
}
