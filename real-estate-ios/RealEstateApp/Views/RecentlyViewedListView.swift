//
//  RecentlyViewedListView.swift
//  RealEstateApp
//
//  最近見た物件一覧。viewedAt でソート、最大30件表示。
//

import SwiftUI
import SwiftData

struct RecentlyViewedListView: View {
    @Query(
        filter: #Predicate<Listing> { $0.viewedAt != nil },
        sort: \Listing.viewedAt,
        order: .reverse
    ) private var recentListings: [Listing]
    @State private var selectedListing: Listing?

    var body: some View {
        List {
            if recentListings.isEmpty {
                ContentUnavailableView(
                    "まだ閲覧した物件がありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("物件の詳細画面を開くと、ここに履歴が表示されます")
                )
            } else {
                ForEach(Array(recentListings.prefix(30)), id: \.url) { listing in
                    Button {
                        selectedListing = listing
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(listing.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(listing.priceDisplayCompact)
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                    if let area = listing.areaM2 {
                                        Text(String(format: "%.1f㎡", area))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let layout = listing.layout {
                                        Text(layout)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if let viewedAt = listing.viewedAt {
                                Text(viewedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("最近見た物件")
        .sheet(item: $selectedListing) { listing in
            ListingDetailView(listing: listing)
        }
    }
}
