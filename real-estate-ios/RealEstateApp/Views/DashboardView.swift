import SwiftUI
import SwiftData

enum DashboardQuickFilter: Hashable {
    case newToday
    case priceDecreased
    case priceIncreased

    var title: String {
        switch self {
        case .newToday: return "本日の新着"
        case .priceDecreased: return "値下げ物件"
        case .priceIncreased: return "値上げ物件"
        }
    }

    var systemImage: String {
        switch self {
        case .newToday: return "sparkles"
        case .priceDecreased: return "arrow.down.circle.fill"
        case .priceIncreased: return "arrow.up.circle.fill"
        }
    }
}

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Listing> { !$0.isDelisted }) private var activeListings: [Listing]
    @State private var selectedListing: Listing?
    @State private var quickFilter: DashboardQuickFilter?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    marketOverviewSection
                    scoreDistributionSection
                    priceChangeSection
                    wardRankingSection
                }
                .padding()
            }
            .navigationTitle("ダッシュボード")
            .fullScreenCover(item: $selectedListing) { listing in
                ListingDetailPagerView(listings: [listing], initialIndex: 0)
            }
            .navigationDestination(item: $quickFilter) { filter in
                DashboardFilteredListView(
                    filter: filter,
                    listings: filteredListings(for: filter)
                )
            }
        }
    }

    // MARK: - マーケット概況

    private var marketOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("マーケット概況", systemImage: "chart.bar.fill")
                .font(.headline)

            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                StatCard(title: "掲載中", value: "\(chukoListings.count)", subtitle: "中古物件", color: .blue)
                StatCard(title: "掲載中", value: "\(shinchikuListings.count)", subtitle: "新築物件", color: .green)
                StatCard(title: "平均価格", value: avgPriceDisplay, subtitle: "中古", color: .orange)
                TappableStatCard(title: "新着", value: "\(newListingsCount)", subtitle: "本日の新着", color: .red, count: newListingsCount) {
                    quickFilter = .newToday
                }
            }

            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                TappableStatCard(title: "値下げ", value: "\(priceDecreasedCount)", subtitle: "価格が下がった物件", color: .green, count: priceDecreasedCount) {
                    quickFilter = .priceDecreased
                }
                TappableStatCard(title: "値上げ", value: "\(priceIncreasedCount)", subtitle: "価格が上がった物件", color: .red, count: priceIncreasedCount) {
                    quickFilter = .priceIncreased
                }
            }
        }
    }

    // MARK: - スコア分布

    private var scoreDistributionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("スコア分布", systemImage: "chart.pie.fill")
                .font(.headline)

            let grades = scoreGrades
            HStack(spacing: 8) {
                GradeBar(label: "S", count: grades.s, total: grades.total, color: .green)
                GradeBar(label: "A", count: grades.a, total: grades.total, color: .blue)
                GradeBar(label: "B", count: grades.b, total: grades.total, color: .orange)
                GradeBar(label: "C", count: grades.c, total: grades.total, color: .gray)
                GradeBar(label: "D", count: grades.d, total: grades.total, color: .red)
            }
            .frame(height: 80)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
            )
        }
    }

    // MARK: - 価格変動物件

    private var priceChangeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("価格変動物件", systemImage: "arrow.up.arrow.down")
                .font(.headline)

            let changed = priceChangedListings
            if changed.isEmpty {
                Text("価格変動のある物件はありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(changed.prefix(10), id: \.url) { listing in
                    Button {
                        selectedListing = listing
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(listing.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(listing.layout ?? "—")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let dateStr = Self.priceChangeDateLabel(for: listing) {
                                        Text("(\(dateStr))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if let change = listing.latestPriceChange {
                                let isDown = change < 0
                                Text("\(isDown ? "↓" : "↑")\(abs(change))万")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                            .fill(.regularMaterial)
                    )
                }
            }
        }
    }

    private static func priceChangeDateLabel(for listing: Listing) -> String? {
        let history = listing.parsedPriceHistory
        guard history.count >= 2, let date = history.last?.parsedDate else { return nil }
        let cal = Calendar.current
        return "\(cal.component(.month, from: date))/\(cal.component(.day, from: date))"
    }

    // MARK: - エリア別坪単価ランキング

    private var wardRankingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("エリア別 坪単価ランキング", systemImage: "chart.bar.xaxis")
                .font(.headline)

            let rankings = wardTsuboRankings
            ForEach(Array(rankings.enumerated()), id: \.element.ward) { index, ranking in
                HStack {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    Text(ranking.ward)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(ranking.avgTsuboPriceMan)万/坪")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("(\(ranking.count)件)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
            )
        }
    }

    // MARK: - Computed Data

    private var chukoListings: [Listing] {
        activeListings.filter { $0.propertyType == "chuko" }
    }

    private var shinchikuListings: [Listing] {
        activeListings.filter { $0.propertyType == "shinchiku" }
    }

    private var avgPriceDisplay: String {
        let prices = chukoListings.compactMap(\.priceMan)
        guard !prices.isEmpty else { return "—" }
        let avg = prices.reduce(0, +) / prices.count
        return Listing.formatPriceCompact(avg)
    }

    private var newListingsCount: Int {
        activeListings.filter(\.isAddedToday).count
    }

    private var priceDecreasedCount: Int {
        activeListings.filter { ($0.latestPriceChange ?? 0) < 0 }.count
    }

    private var priceIncreasedCount: Int {
        activeListings.filter { ($0.latestPriceChange ?? 0) > 0 }.count
    }

    private func filteredListings(for filter: DashboardQuickFilter) -> [Listing] {
        switch filter {
        case .newToday:
            return activeListings.filter(\.isAddedToday)
                .sorted { $0.addedAt > $1.addedAt }
        case .priceDecreased:
            return activeListings.filter { ($0.latestPriceChange ?? 0) < 0 }
                .sorted { abs($0.latestPriceChange ?? 0) > abs($1.latestPriceChange ?? 0) }
        case .priceIncreased:
            return activeListings.filter { ($0.latestPriceChange ?? 0) > 0 }
                .sorted { abs($0.latestPriceChange ?? 0) > abs($1.latestPriceChange ?? 0) }
        }
    }

    private var priceChangedListings: [Listing] {
        activeListings
            .filter { $0.latestPriceChange != nil && $0.latestPriceChange != 0 }
            .sorted { abs($0.latestPriceChange ?? 0) > abs($1.latestPriceChange ?? 0) }
    }

    private var scoreGrades: (s: Int, a: Int, b: Int, c: Int, d: Int, total: Int) {
        var s = 0, a = 0, b = 0, c = 0, d = 0
        for listing in activeListings {
            guard let score = listing.listingScore else { continue }
            switch score {
            case 80...: s += 1
            case 65..<80: a += 1
            case 50..<65: b += 1
            case 35..<50: c += 1
            default: d += 1
            }
        }
        let total = s + a + b + c + d
        return (s, a, b, c, d, max(total, 1))
    }

    struct WardRanking: Hashable {
        let ward: String
        let avgTsuboPriceMan: Int
        let count: Int
    }

    private var wardTsuboRankings: [WardRanking] {
        var wardData: [String: (totalPrice: Int, totalArea: Double, count: Int)] = [:]
        for listing in chukoListings {
            guard let price = listing.priceMan, let area = listing.areaM2, area > 0 else { continue }
            let ward = listing.wardName
            guard !ward.isEmpty else { continue }
            let existing = wardData[ward] ?? (0, 0, 0)
            wardData[ward] = (existing.totalPrice + price, existing.totalArea + area, existing.count + 1)
        }
        return wardData.map { ward, data in
            let m2Price = Double(data.totalPrice) / data.totalArea
            WardRanking(ward: ward, avgTsuboPriceMan: Int(m2Price * 3.30578), count: data.count)
        }
        .sorted { $0.avgTsuboPriceMan > $1.avgTsuboPriceMan }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        )
    }
}

/// タップ可能な StatCard。該当件数が0のときはタップ不可で通常の StatCard と同じ見た目。
private struct TappableStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(color)
                HStack(spacing: 2) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if count > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
            )
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
    }
}

private struct GradeBar: View {
    let label: String
    let count: Int
    let total: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            GeometryReader { geo in
                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.3))
                        .frame(height: max(4, geo.size.height * CGFloat(count) / CGFloat(total)))
                }
            }
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dashboard Filtered List

/// ダッシュボードのクイックフィルタ（新着/値下げ/値上げ）で絞り込んだ物件一覧
struct DashboardFilteredListView: View {
    let filter: DashboardQuickFilter
    let listings: [Listing]
    @State private var selectedListing: Listing?

    var body: some View {
        Group {
            if listings.isEmpty {
                ContentUnavailableView {
                    Label("該当する物件がありません", systemImage: filter.systemImage)
                }
            } else {
                List(listings, id: \.url) { listing in
                    Button {
                        selectedListing = listing
                    } label: {
                        DashboardFilteredRow(listing: listing, filter: filter)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(filter.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedListing) { listing in
            let index = listings.firstIndex(where: { $0.url == listing.url }) ?? 0
            ListingDetailPagerView(listings: listings, initialIndex: index)
        }
    }
}

/// フィルタ一覧の行表示
private struct DashboardFilteredRow: View {
    let listing: Listing
    let filter: DashboardQuickFilter

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let thumbURL = listing.thumbnailURL {
                TrimmedAsyncImage(url: thumbURL, width: 80)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(listing.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(listing.priceDisplayCompact)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(listing.isShinchiku ? DesignSystem.shinchikuPriceColor : Color.accentColor)

                    if filter != .newToday, let change = listing.latestPriceChange, change != 0 {
                        let isDown = change < 0
                        Text("\(isDown ? "↓" : "↑")\(abs(change))万")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor).opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                HStack(spacing: 4) {
                    Text(listing.layout ?? "—")
                    Text(listing.areaDisplay)
                    Text(listing.builtAgeDisplay)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let line = listing.displayStationLine, !line.isEmpty {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
