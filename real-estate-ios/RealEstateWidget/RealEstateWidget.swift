import WidgetKit
import SwiftUI
import UIKit

/// App 側 WidgetPayload（RealEstateApp/Services/WidgetDataProvider.swift）と JSON 形状を共有する。
/// 追加フィールドは optional にして旧データとの decode 互換を保つ。
struct WidgetData: Codable {
    let totalListings: Int
    let newListings: Int
    let likedCount: Int
    let lastUpdated: Date
    let priceChanges: Int
    let likedSummaries: [LikedSummary]
    var featuredItems: [Featured]?
    var briefText: String?

    struct LikedSummary: Codable {
        let name: String
        let priceMan: Int?
        let priceChange: Int?
    }

    struct Featured: Codable {
        let url: String
        let name: String
        let priceText: String
        let gradeLetter: String?
        let isNew: Bool
        let imageFileName: String?
    }

    static let placeholder = WidgetData(
        totalListings: 0,
        newListings: 0,
        likedCount: 0,
        lastUpdated: .now,
        priceChanges: 0,
        likedSummaries: [],
        featuredItems: [],
        briefText: nil
    )
}

/// ウィジェット内ローカルのアクセント色（DesignSystem は app target 限定のため共有しない）。
private enum WidgetTheme {
    static let accent = Color(red: 0x0E / 255, green: 0x7C / 255, blue: 0x7B / 255) // ディープティール
    static let priceDown = Color(red: 0.18, green: 0.53, blue: 0.76)
    static let priceUp = Color(red: 0.90, green: 0.49, blue: 0.13)
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

/// App Group コンテナの画像ファイルを読む（ファイル名のみを WidgetData から受け取る）。
private func featuredImage(_ fileName: String?) -> UIImage? {
    guard let fileName,
          let container = FileManager.default.containerURL(
              forSecurityApplicationGroupIdentifier: "group.com.hanawa.realestate"
          ) else { return nil }
    return UIImage(contentsOfFile: container.appendingPathComponent(fileName).path)
}

/// ウィジェットタップ用ディープリンク（app の WidgetDeepLink と同形式）。
private func deepLinkURL(forListingURL listingURL: String) -> URL? {
    var components = URLComponents()
    components.scheme = "realestate"
    components.host = "listing"
    components.queryItems = [URLQueryItem(name: "u", value: listingURL)]
    return components.url
}

struct RealEstateWidget: Widget {
    let kind = "RealEstateWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            RealEstateWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("今日の1枚")
        .description("新着の注目物件とAIブリーフを表示します")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RealEstateWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: RealEstateEntry

    private var featured: [WidgetData.Featured] { entry.data.featuredItems ?? [] }

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

    // MARK: - Small（今日の1枚）

    @ViewBuilder
    private var smallWidget: some View {
        if let item = featured.first {
            featuredCard(item)
                .widgetURL(deepLinkURL(forListingURL: item.url))
        } else {
            countsFallbackSmall
        }
    }

    private func featuredCard(_ item: WidgetData.Featured) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let image = featuredImage(item.imageFileName) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 78)
                        .clipped()
                } else {
                    WidgetTheme.accent.opacity(0.12)
                        .frame(height: 78)
                        .overlay(
                            Image(systemName: "building.2")
                                .font(.title2)
                                .foregroundStyle(WidgetTheme.accent)
                        )
                }
                HStack(spacing: 4) {
                    if item.isNew {
                        Text("NEW").font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(WidgetTheme.accent, in: Capsule())
                    }
                    if let grade = item.gradeLetter {
                        Text(grade).font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.priceText)
                    .font(.callout.bold())
                    .foregroundStyle(WidgetTheme.accent)
                    .lineLimit(1)
                Text(item.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private var countsFallbackSmall: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "building.2").font(.title3).foregroundStyle(WidgetTheme.accent)
                Spacer()
                Text(entry.data.lastUpdated, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.data.newListings > 0 {
                HStack(spacing: 4) {
                    Text("新着").font(.caption2).foregroundStyle(.secondary)
                    Text("\(entry.data.newListings)件").font(.title2).fontWeight(.bold)
                        .foregroundStyle(WidgetTheme.accent)
                }
            }
            HStack(spacing: 4) {
                Text("全").font(.caption2).foregroundStyle(.secondary)
                Text("\(entry.data.totalListings)件").font(.callout).fontWeight(.semibold)
            }
        }
        .padding(2)
    }

    // MARK: - Medium（ブリーフ1文＋2物件）

    @ViewBuilder
    private var mediumWidget: some View {
        if featured.isEmpty {
            countsFallbackMedium
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let brief = entry.data.briefText, !brief.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(WidgetTheme.accent)
                        Text(brief).font(.caption2).foregroundStyle(.primary).lineLimit(2)
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "building.2").font(.caption).foregroundStyle(WidgetTheme.accent)
                        Text("今日の新着").font(.caption.weight(.semibold))
                    }
                }
                Divider()
                ForEach(Array(featured.prefix(2).enumerated()), id: \.offset) { _, item in
                    Link(destination: deepLinkURL(forListingURL: item.url) ?? URL(string: "realestate://")!) {
                        listingRow(item)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(4)
        }
    }

    private func listingRow(_ item: WidgetData.Featured) -> some View {
        HStack(spacing: 8) {
            if let grade = item.gradeLetter {
                Text(grade)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(WidgetTheme.accent, in: RoundedRectangle(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.caption2).foregroundStyle(.primary).lineLimit(1)
                Text(item.priceText).font(.caption2.bold()).foregroundStyle(WidgetTheme.accent).lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isNew {
                Text("NEW").font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(WidgetTheme.accent, in: Capsule())
            }
        }
    }

    private var countsFallbackMedium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "building.2").font(.title3).foregroundStyle(WidgetTheme.accent)
                    Text("物件情報").font(.headline)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("新着").font(.caption).foregroundStyle(.secondary)
                    Text("\(entry.data.newListings)件").font(.title2).fontWeight(.bold)
                        .foregroundStyle(WidgetTheme.accent)
                }
                HStack(spacing: 8) {
                    Label("\(entry.data.totalListings)件", systemImage: "house")
                    Label("\(entry.data.likedCount)件", systemImage: "heart.fill")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("いいね物件").font(.caption).foregroundStyle(.secondary)
                if entry.data.likedSummaries.isEmpty {
                    Text("いいね物件がありません").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxHeight: .infinity)
                } else {
                    ForEach(0..<min(3, entry.data.likedSummaries.count), id: \.self) { i in
                        let s = entry.data.likedSummaries[i]
                        HStack {
                            Text(s.name).font(.caption2).lineLimit(1)
                            Spacer()
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(2)
    }
}
