import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Listing> { !$0.isDelisted }) private var activeListings: [Listing]

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
                StatCard(title: "新着", value: "\(newListingsCount)", subtitle: "本日の新着", color: .red)
            }

            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                StatCard(title: "値下げ", value: "\(priceDecreasedCount)", subtitle: "価格が下がった物件", color: .green)
                StatCard(title: "値上げ", value: "\(priceIncreasedCount)", subtitle: "価格が上がった物件", color: .red)
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
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(listing.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(listing.layout ?? "—")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let change = listing.latestPriceChange {
                            let isDown = change < 0
                            Text("\(isDown ? "↓" : "↑")\(abs(change))万")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(isDown ? DesignSystem.priceDownColor : DesignSystem.priceUpColor)
                        }
                    }
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

    // MARK: - エリア別坪単価ランキング

    private var wardRankingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("エリア別 m²単価ランキング", systemImage: "chart.bar.xaxis")
                .font(.headline)

            let rankings = wardM2Rankings
            ForEach(Array(rankings.enumerated()), id: \.element.ward) { index, ranking in
                HStack {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 24)
                        .foregroundStyle(.secondary)
                    Text(ranking.ward)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(ranking.avgM2PriceMan)万/m²")
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
        let avgM2PriceMan: Int
        let count: Int
    }

    private var wardM2Rankings: [WardRanking] {
        var wardData: [String: (totalPrice: Int, totalArea: Double, count: Int)] = [:]
        for listing in chukoListings {
            guard let price = listing.priceMan, let area = listing.areaM2, area > 0 else { continue }
            let ward = listing.wardName
            guard !ward.isEmpty else { continue }
            let existing = wardData[ward] ?? (0, 0, 0)
            wardData[ward] = (existing.totalPrice + price, existing.totalArea + area, existing.count + 1)
        }
        return wardData.map { ward, data in
            WardRanking(ward: ward, avgM2PriceMan: Int(Double(data.totalPrice) / data.totalArea), count: data.count)
        }
        .sorted { $0.avgM2PriceMan > $1.avgM2PriceMan }
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
