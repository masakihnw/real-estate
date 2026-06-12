//
//  ActivityFeedView.swift
//  RealEstateApp
//
//  「すべての動き」: 直近の新着・再掲・価格変動のタイムライン全文。
//  Today タブの NavigationStack に push される（自前 NavigationStack を持たない）。
//

import SwiftUI
import SwiftData

struct ActivityFeedView: View {
    @Query(filter: #Predicate<Listing> { !$0.isDelisted && $0.propertyType == "chuko" })
    private var activeListings: [Listing]
    @State private var selectedListing: Listing?

    var body: some View {
        let items = TimelineFeed.build(from: activeListings, days: 7, limit: 100)
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "直近7日の動きはありません",
                    systemImage: "moon.zzz",
                    description: Text("新着・値下げ・再掲載が発生するとここに表示されます")
                )
            } else {
                List(items) { item in
                    Button {
                        selectedListing = item.listing
                    } label: {
                        feedRow(item)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("すべての動き")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // ウォッチリスト（注目物件の値下げ一覧）への暫定導線。
                // Phase 5 でマイリストの自動ソートに統合予定。
                NavigationLink {
                    WatchlistView()
                } label: {
                    Image(systemName: "heart.text.square")
                }
                .accessibilityLabel("ウォッチリスト")
            }
        }
        .fullScreenCover(item: $selectedListing) { listing in
            ListingDetailPagerView(listings: [listing], initialIndex: 0)
        }
    }

    private func feedRow(_ item: TimelineFeedItem) -> some View {
        HStack(spacing: DS.Spacing.md) {
            Image(systemName: item.kind.systemImage)
                .font(DS.Typography.sectionTitle)
                .foregroundStyle(iconColor(for: item.kind))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.sm) {
                    Text(item.kind.label)
                        .font(DS.Typography.badge)
                        .foregroundStyle(iconColor(for: item.kind))
                    Text(item.date, style: .date)
                        .font(DS.Typography.label)
                        .foregroundStyle(.secondary)
                }
                Text(item.listing.name)
                    .font(DS.Typography.body)
                    .lineLimit(1)
                HStack(spacing: DS.Spacing.sm) {
                    if let price = item.listing.priceMan {
                        PriceText(priceMan: price, style: .compact)
                            .foregroundStyle(.secondary)
                    }
                    switch item.kind {
                    case .priceDrop(let amount):
                        DeltaBadge(deltaMan: -amount)
                    case .priceRaise(let amount):
                        DeltaBadge(deltaMan: amount)
                    default:
                        EmptyView()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private func iconColor(for kind: TimelineFeedItem.Kind) -> Color {
        switch kind {
        case .added:      Color.accentColor
        case .relisted:   .orange
        case .priceDrop:  DesignSystem.priceDownColor
        case .priceRaise: DesignSystem.priceUpColor
        }
    }
}

#Preview {
    NavigationStack {
        ActivityFeedView()
    }
    .modelContainer(for: [Listing.self], inMemory: true)
}
