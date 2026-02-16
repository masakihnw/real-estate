//
//  ListingDetailPagerView.swift
//  RealEstateApp
//
//  全物件スワイプページャー。フィルタ済み物件リストを横スワイプで横断比較可能にする。
//  各ページは既存の ListingDetailView をそのまま表示する。
//

import SwiftUI

struct ListingDetailPagerView: View {
    let listings: [Listing]
    @State private var currentIndex: Int

    init(listings: [Listing], initialIndex: Int) {
        self.listings = listings
        self._currentIndex = State(initialValue: min(initialIndex, max(listings.count - 1, 0)))
    }

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(listings.enumerated()), id: \.element.url) { index, listing in
                ListingDetailView(listing: listing)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            if listings.count > 1 {
                pageIndicator
                    .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation {
                    currentIndex = max(0, currentIndex - 1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
            }
            .disabled(currentIndex == 0)
            .opacity(currentIndex == 0 ? 0.3 : 1.0)

            Text("\(currentIndex + 1) / \(listings.count)")
                .font(.caption.weight(.medium))
                .monospacedDigit()

            Button {
                withAnimation {
                    currentIndex = min(listings.count - 1, currentIndex + 1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .disabled(currentIndex == listings.count - 1)
            .opacity(currentIndex == listings.count - 1 ? 0.3 : 1.0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

#Preview {
    ListingDetailPagerView(
        listings: [],
        initialIndex: 0
    )
}
