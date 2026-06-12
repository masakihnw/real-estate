import SwiftUI
import SwiftData

/// Nope（見送り）した物件の管理画面。マイリストのツールバーから到達する。
/// 個別解除と一括解除（確認ダイアログ付き）を提供。
struct NopedListingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var nopedListings: [Listing] = []
    @State private var selectedListing: Listing?
    @State private var showClearAllConfirm = false
    @State private var isClearing = false
    @State private var clearError: String?

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
        .toolbar {
            if !nopedListings.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearAllConfirm = true
                    } label: {
                        if isClearing {
                            ProgressView()
                        } else {
                            Text("すべて解除")
                        }
                    }
                    .disabled(isClearing)
                }
            }
        }
        .confirmationDialog(
            "\(nopedListings.count)件のNopeをすべて解除しますか？",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("すべて解除", role: .destructive) {
                clearAll()
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("解除した物件は一覧・スワイプに再び表示されます")
        }
        .alert("一括解除エラー", isPresented: Binding(
            get: { clearError != nil },
            set: { if !$0 { clearError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(clearError ?? "")
        }
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
                    Text(listing.nameWithFloor)
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
        let descriptor = FetchDescriptor<Listing>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        nopedListings = NopedFilter.filter(listings: all, nopedKeys: nopedKeys)
    }

    private func clearAll() {
        let keys = nopedListings.map(\.identityKey)
        guard !keys.isEmpty else { return }
        isClearing = true
        Task {
            let failedCount = await BuildingPreferenceStore.shared.removePreferences(keys)
            if failedCount == 0 {
                HapticManager.success()
            } else {
                HapticManager.error()
                clearError = "\(failedCount)件の解除に失敗しました。通信状況を確認して再試行してください。"
            }
            loadNoped()
            isClearing = false
        }
    }
}
