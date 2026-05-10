import SwiftUI
import SwiftData

struct NopedListingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var nopedListings: [Listing] = []
    @State private var selectedListing: Listing?

    var body: some View {
        Group {
            if nopedListings.isEmpty {
                ContentUnavailableView(
                    "Nopeした物件はありません",
                    systemImage: "hand.thumbsdown",
                    description: Text("物件を左スワイプでNopeすると、一覧から非表示になります")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(nopedListings, id: \.url) { listing in
                            nopedRow(listing)
                            Divider()
                        }
                    }
                }
            }
        }
        .navigationTitle("Nopeした物件")
        .onAppear { loadNoped() }
        .fullScreenCover(item: $selectedListing) { listing in
            ListingDetailView(listing: listing)
        }
    }

    @ViewBuilder
    private func nopedRow(_ listing: Listing) -> some View {
        HStack {
            Button {
                selectedListing = listing
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(listing.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(listing.priceDisplayCompact)
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text(listing.layout ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(listing.areaDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                Task {
                    await BuildingPreferenceStore.shared.removePreference(listing.identityKey)
                    loadNoped()
                }
            } label: {
                Text("解除")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.blue, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func loadNoped() {
        let nopedKeys = BuildingPreferenceStore.shared.nopedKeys
        guard !nopedKeys.isEmpty else {
            nopedListings = []
            return
        }
        let descriptor = FetchDescriptor<Listing>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        nopedListings = all.filter { nopedKeys.contains($0.identityKey) }
    }
}
