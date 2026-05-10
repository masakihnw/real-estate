import SwiftUI
import SwiftData

struct MyListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allListings: [Listing]

    @State private var favoriteListings: [Listing] = []
    @State private var likedListings: [Listing] = []
    @State private var nopedListings: [Listing] = []
    @State private var selectedListing: Listing?
    @State private var isNopeExpanded = false

    private let prefStore = BuildingPreferenceStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if favoriteListings.isEmpty && likedListings.isEmpty && nopedListings.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("マイリスト")
            .onAppear { reload() }
            .onChange(of: prefStore.likedKeys.count) { _, _ in reload() }
            .onChange(of: prefStore.nopedKeys.count) { _, _ in reload() }
            .fullScreenCover(item: $selectedListing) { listing in
                ListingDetailView(listing: listing)
            }
        }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            if !favoriteListings.isEmpty {
                Section {
                    ForEach(favoriteListings, id: \.url) { listing in
                        listingRow(listing, style: .favorite)
                    }
                } header: {
                    Label("いいね", systemImage: "heart.fill")
                        .foregroundStyle(.red)
                }
            }

            if !likedListings.isEmpty {
                Section {
                    ForEach(likedListings, id: \.url) { listing in
                        listingRow(listing, style: .liked)
                    }
                } header: {
                    Label("Like", systemImage: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }

            if !nopedListings.isEmpty {
                Section(isExpanded: $isNopeExpanded) {
                    ForEach(nopedListings, id: \.url) { listing in
                        listingRow(listing, style: .noped)
                    }
                } header: {
                    HStack {
                        Label("Nope", systemImage: "hand.thumbsdown")
                        Spacer()
                        Text("\(nopedListings.count)件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: favoriteListings.count)
        .animation(.default, value: likedListings.count)
        .animation(.default, value: nopedListings.count)
    }

    // MARK: - Row

    private enum RowStyle { case favorite, liked, noped }

    @ViewBuilder
    private func listingRow(_ listing: Listing, style: RowStyle) -> some View {
        HStack {
            Button {
                selectedListing = listing
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(listing.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(listing.isDelisted ? .secondary : .primary)
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
            removeButton(listing, style: style)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func removeButton(_ listing: Listing, style: RowStyle) -> some View {
        switch style {
        case .favorite:
            Button {
                listing.isLiked = false
                SaveErrorHandler.shared.save(modelContext, source: "MyList")
                AnnotationRouter.pushLikeState(for: listing)
                reload()
            } label: {
                removeLabel("解除")
            }
            .buttonStyle(.plain)
        case .liked:
            Button {
                Task {
                    await prefStore.removePreference(listing.identityKey)
                    reload()
                }
            } label: {
                removeLabel("解除")
            }
            .buttonStyle(.plain)
        case .noped:
            Button {
                Task {
                    await prefStore.removePreference(listing.identityKey)
                    reload()
                }
            } label: {
                removeLabel("解除")
            }
            .buttonStyle(.plain)
        }
    }

    private func removeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.blue, in: Capsule())
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("マイリストは空です", systemImage: "tray")
        } description: {
            Text("物件一覧でハート(♥)やスワイプ(★/👎)を使うとここに表示されます。")
        }
    }

    // MARK: - Data

    private func reload() {
        let liked = prefStore.likedKeys
        let noped = prefStore.nopedKeys

        favoriteListings = allListings
            .filter { $0.isLiked }
            .sorted { ($0.priceMan ?? 0) < ($1.priceMan ?? 0) }
        likedListings = allListings
            .filter { liked.contains($0.identityKey) }
            .sorted { ($0.priceMan ?? 0) < ($1.priceMan ?? 0) }
        nopedListings = allListings
            .filter { noped.contains($0.identityKey) }
            .sorted { ($0.priceMan ?? 0) < ($1.priceMan ?? 0) }
    }
}

#Preview {
    MyListView()
        .modelContainer(for: Listing.self, inMemory: true)
}
