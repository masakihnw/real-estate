import SwiftUI
import SwiftData

/// ウォッチリスト画面。
///
/// いいね済み or 高評価（S/A）の物件を「値下げあり」「変動なし」に分けて一覧表示する。
/// 従来は Slack 通知のみだったウォッチリストをアプリ内で確認できるようにしたもの。
/// 抽出ロジックは WatchlistFilter（Dashboard と共通）。
struct WatchlistView: View {
    @Query(filter: #Predicate<Listing> { !$0.isDelisted && $0.propertyType == "chuko" })
    private var activeListings: [Listing]

    @State private var selectedListing: Listing?

    private var watchlisted: [Listing] {
        activeListings.filter { WatchlistFilter.isWatchlisted($0) }
    }

    private var dropped: [Listing] {
        WatchlistFilter.priceDrops(in: watchlisted, limit: Int.max)
    }

    private var unchanged: [Listing] {
        let droppedURLs = Set(dropped.map(\.url))
        return watchlisted
            .filter { !droppedURLs.contains($0.url) }
            .sorted { ($0.priceMan ?? 0) < ($1.priceMan ?? 0) }
    }

    var body: some View {
        List {
            if watchlisted.isEmpty {
                ContentUnavailableView(
                    "ウォッチ中の物件がありません",
                    systemImage: "bell.slash",
                    description: Text("いいねした物件と高評価（S/A）の物件がここに表示されます")
                )
                .listRowSeparator(.hidden)
            }

            if !dropped.isEmpty {
                Section {
                    ForEach(dropped, id: \.url) { listing in
                        WatchlistRow(listing: listing, showDrop: true) {
                            selectedListing = listing
                        }
                    }
                } header: {
                    Label("値下げあり（\(dropped.count)件）", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(DesignSystem.priceDownColor)
                }
            }

            if !unchanged.isEmpty {
                Section {
                    ForEach(unchanged, id: \.url) { listing in
                        WatchlistRow(listing: listing, showDrop: false) {
                            selectedListing = listing
                        }
                    }
                } header: {
                    Label("ウォッチ中（\(unchanged.count)件）", systemImage: "eye")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("ウォッチリスト")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedListing) { listing in
            ListingDetailPagerView(listings: [listing], initialIndex: 0)
        }
    }
}

private struct WatchlistRow: View {
    let listing: Listing
    let showDrop: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let thumbURL = listing.thumbnailURL {
                    TrimmedAsyncImage(url: thumbURL, width: 52, height: 52)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if listing.isLiked {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                        }
                        if let grade = listing.assetGrade, WatchlistFilter.highGrades.contains(grade) {
                            Text(grade)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(grade == "S" ? Color.orange : DesignSystem.aiAccent)
                                )
                        }
                        Text(listing.nameWithFloor)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let price = listing.priceMan {
                            Text(Listing.formatPriceCompact(price))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        if showDrop, let change = listing.latestPriceChange, change < 0 {
                            Text("↓\(abs(change))万")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(DesignSystem.priceDownColor)
                        }
                        Text(listing.daysOnMarketDisplay)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
