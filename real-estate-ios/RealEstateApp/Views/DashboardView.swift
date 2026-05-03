import SwiftUI
import SwiftData

enum DashboardQuickFilter: Hashable {
    case newToday
    case priceDecreased
    case priceIncreased
    case favorites

    var title: String {
        switch self {
        case .newToday: return "本日の新着"
        case .priceDecreased: return "値下げ物件"
        case .priceIncreased: return "値上げ物件"
        case .favorites: return "お気に入り"
        }
    }

    var systemImage: String {
        switch self {
        case .newToday: return "sparkles"
        case .priceDecreased: return "arrow.down.circle.fill"
        case .priceIncreased: return "arrow.up.circle.fill"
        case .favorites: return "heart.fill"
        }
    }
}

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Listing> { !$0.isDelisted }) private var activeListings: [Listing]
    @Query(filter: #Predicate<Listing> { $0.isLiked == true }) private var favoriteListings: [Listing]
    @State private var selectedListing: Listing?
    @State private var quickFilter: DashboardQuickFilter?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    searchOverviewSection
                    quickFiltersSection
                    aiInsightsSection
                    scoreDistributionSection
                    priceMoversSection
                    areaRankingSection
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

    // MARK: - 検索状況 (Search Overview)

    private var searchOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("検索状況", systemImage: "magnifyingglass")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 12) {
                DashboardStatCard(
                    title: "候補物件",
                    value: "\(activeListings.count)",
                    color: .primary
                )
                DashboardStatCard(
                    title: "本日新着",
                    value: "\(newListingsCount)",
                    color: DesignSystem.priceDownColor
                )
                DashboardStatCard(
                    title: "お気に入り",
                    value: "\(favoriteListings.count)",
                    color: .primary
                )
            }
        }
    }

    // MARK: - Quick Filters

    private var quickFiltersSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                QuickFilterButton(icon: "sparkles", label: "本日の新着", count: newListingsCount) {
                    quickFilter = .newToday
                }
                QuickFilterButton(icon: "arrow.down.circle.fill", label: "値下げ物件", count: priceDecreasedCount) {
                    quickFilter = .priceDecreased
                }
                QuickFilterButton(icon: "arrow.up.circle.fill", label: "値上げ物件", count: priceIncreasedCount) {
                    quickFilter = .priceIncreased
                }
                QuickFilterButton(icon: "heart.fill", label: "お気に入り", count: favoriteListings.count) {
                    quickFilter = .favorites
                }
            }
        }
    }

    // MARK: - AI Insights

    private var aiInsightsSection: some View {
        let topListings = chukoListings
            .filter { $0.highlightBadge != nil && $0.investmentSummary != nil }
            .sorted { ($0.listingScore ?? 0) > ($1.listingScore ?? 0) }
            .prefix(3)

        let dedupCount = chukoListings.filter { !$0.parsedDedupCandidates.isEmpty }.count

        return Group {
            if !topListings.isEmpty || dedupCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("AI Insights", systemImage: "sparkles")
                            .font(.headline)
                        Spacer()
                        // AI badge in indigo
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                            Text("AI")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(DesignSystem.aiAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(DesignSystem.aiAccentTint)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }

                    if !topListings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("注目物件 Top 3")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            ForEach(Array(topListings), id: \.url) { listing in
                                Button {
                                    selectedListing = listing
                                } label: {
                                    HStack(spacing: 10) {
                                        // Thumbnail
                                        if let thumbURL = listing.thumbnailURL {
                                            AsyncImage(url: thumbURL) { image in
                                                image.resizable().scaledToFill()
                                            } placeholder: {
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color(.systemGray5))
                                            }
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(listing.name)
                                                .font(.caption.weight(.medium))
                                                .lineLimit(1)
                                            if let monthly = listing.estimatedMonthlyPayment {
                                                Text("月々 \(String(format: "%.1f", monthly))万円")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        // Score badge
                                        if let grade = listing.scoreGradeLetter {
                                            Text(grade)
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                                .frame(width: 24, height: 24)
                                                .background(DesignSystem.scoreColor(for: grade))
                                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                        }

                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Dedup alert card
                    if dedupCount > 0 {
                        HStack(spacing: 8) {
                            Image(systemName: "link.badge.plus")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(dedupCount)件の重複候補を検出")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                                Text("同マンション内の別出品の可能性があります")
                                    .font(.caption2)
                                    .foregroundStyle(.orange.opacity(0.8))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .tintedGlassBackground(tint: .orange, tintOpacity: 0.06, borderOpacity: 0.15)
                    }
                }
                .padding()
                .listingGlassBackground()
            }
        }
    }

    // MARK: - おすすめ度の分布 (Score Distribution)

    private var scoreDistributionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("おすすめ度の分布", systemImage: "chart.bar.fill")
                .font(.headline)

            let grades = scoreGrades
            VStack(spacing: 8) {
                ScoreDistributionBar(grade: "S", count: grades.s, maxCount: grades.maxCount)
                ScoreDistributionBar(grade: "A", count: grades.a, maxCount: grades.maxCount)
                ScoreDistributionBar(grade: "B", count: grades.b, maxCount: grades.maxCount)
                ScoreDistributionBar(grade: "C", count: grades.c, maxCount: grades.maxCount)
                ScoreDistributionBar(grade: "D", count: grades.d, maxCount: grades.maxCount)
            }
            .padding(14)
            .listingGlassBackground()
        }
    }

    // MARK: - 価格変動 (Price Movers)

    private var priceMoversSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("価格変動", systemImage: "arrow.up.arrow.down")
                .font(.headline)

            let decreased = priceDecreasedListings.prefix(3)
            let increased = priceIncreasedListings.prefix(3)

            if decreased.isEmpty && increased.isEmpty {
                Text("価格変動のある物件はありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                if !decreased.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("値下げ Top 3")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(DesignSystem.priceDownColor)
                        ForEach(Array(decreased), id: \.url) { listing in
                            PriceMoverRow(listing: listing, isDown: true) {
                                selectedListing = listing
                            }
                        }
                    }
                }

                if !increased.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("値上げ Top 3")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(DesignSystem.priceUpColor)
                        ForEach(Array(increased), id: \.url) { listing in
                            PriceMoverRow(listing: listing, isDown: false) {
                                selectedListing = listing
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - エリアランキング (Area Ranking)

    private var areaRankingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("エリアランキング", systemImage: "chart.bar.xaxis")
                .font(.headline)

            let rankings = wardScoreRankings
            if rankings.isEmpty {
                Text("データがありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(rankings.prefix(5).enumerated()), id: \.element.ward) { index, ranking in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .frame(width: 20)
                                .foregroundStyle(index < 3 ? DesignSystem.aiAccent : .secondary)
                            Text(ranking.ward)
                                .font(.caption.weight(.semibold))
                                .frame(width: 60, alignment: .leading)

                            GeometryReader { geo in
                                let maxScore = rankings.first?.avgScore ?? 1
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(DesignSystem.scoreColor(for: gradeForScore(ranking.avgScore)))
                                    .frame(width: max(4, geo.size.width * CGFloat(ranking.avgScore) / CGFloat(max(maxScore, 1))))
                            }
                            .frame(height: 12)

                            Text("\(ranking.avgScore)")
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(14)
                .listingGlassBackground()
            }
        }
    }

    // MARK: - Computed Data

    private var chukoListings: [Listing] {
        activeListings.filter { $0.propertyType == "chuko" }
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

    private var priceDecreasedListings: [Listing] {
        activeListings
            .filter { ($0.latestPriceChange ?? 0) < 0 }
            .sorted { abs($0.latestPriceChange ?? 0) > abs($1.latestPriceChange ?? 0) }
    }

    private var priceIncreasedListings: [Listing] {
        activeListings
            .filter { ($0.latestPriceChange ?? 0) > 0 }
            .sorted { abs($0.latestPriceChange ?? 0) > abs($1.latestPriceChange ?? 0) }
    }

    private func filteredListings(for filter: DashboardQuickFilter) -> [Listing] {
        switch filter {
        case .newToday:
            return activeListings.filter(\.isAddedToday)
                .sorted { $0.addedAt > $1.addedAt }
        case .priceDecreased:
            return priceDecreasedListings
        case .priceIncreased:
            return priceIncreasedListings
        case .favorites:
            return favoriteListings
        }
    }

    private var scoreGrades: (s: Int, a: Int, b: Int, c: Int, d: Int, maxCount: Int) {
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
        let maxCount = max(max(s, a, b, c, d), 1)
        return (s, a, b, c, d, maxCount)
    }

    struct WardScoreRanking: Hashable {
        let ward: String
        let avgScore: Int
        let count: Int
    }

    private var wardScoreRankings: [WardScoreRanking] {
        var wardData: [String: (totalScore: Int, count: Int)] = [:]
        for listing in activeListings {
            guard let score = listing.listingScore else { continue }
            let ward = listing.wardName
            guard !ward.isEmpty else { continue }
            let existing = wardData[ward] ?? (0, 0)
            wardData[ward] = (existing.totalScore + score, existing.count + 1)
        }
        return wardData.map { (ward, data) -> WardScoreRanking in
            WardScoreRanking(ward: ward, avgScore: data.totalScore / max(data.count, 1), count: data.count)
        }
        .sorted { $0.avgScore > $1.avgScore }
    }

    private func gradeForScore(_ score: Int) -> String {
        // Mirrors Listing.scoreGradeLetter thresholds
        switch score {
        case 80...: return "S"
        case 65..<80: return "A"
        case 50..<65: return "B"
        case 35..<50: return "C"
        default: return "D"
        }
    }
}

// MARK: - Dashboard Stat Card

private struct DashboardStatCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .listingGlassBackground()
    }
}

// MARK: - Quick Filter Button

private struct QuickFilterButton: View {
    let icon: String
    let label: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1.0)
    }
}

// MARK: - Score Distribution Bar (horizontal)

private struct ScoreDistributionBar: View {
    let grade: String
    let count: Int
    let maxCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(grade)
                .font(.caption.weight(.bold))
                .foregroundStyle(DesignSystem.scoreColor(for: grade))
                .frame(width: 16, alignment: .center)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(DesignSystem.scoreColor(for: grade).opacity(0.7))
                    .frame(width: max(4, geo.size.width * CGFloat(count) / CGFloat(max(maxCount, 1))))
            }
            .frame(height: 14)

            Text("\(count)件")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Price Mover Row

private struct PriceMoverRow: View {
    let listing: Listing
    let isDown: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let price = listing.priceMan {
                        HStack(spacing: 4) {
                            Text(Listing.formatPriceCompact(price))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let change = listing.latestPriceChange {
                                let delta = abs(change)
                                Text("\(isDown ? "↓" : "↑")\(delta)万")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor)
                                // Percentage relative to original price
                                let originalPrice = isDown ? price + delta : price - delta
                                if originalPrice > 0 {
                                    let pct = Double(delta) / Double(originalPrice) * 100
                                    Text("(\(String(format: "%.1f", pct))%)")
                                        .font(.caption2)
                                        .foregroundStyle(isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor)
                                }
                            }
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous)
                    .fill((isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor).opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dashboard Filtered List

/// ダッシュボードのクイックフィルタ（新着/値下げ/値上げ/お気に入り）で絞り込んだ物件一覧
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

                    if filter != .newToday && filter != .favorites, let change = listing.latestPriceChange, change != 0 {
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
