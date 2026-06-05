import SwiftUI

struct SwipeSessionView: View {
    let listings: [Listing]
    let onDismiss: () -> Void

    @State private var viewModel = SwipeSessionViewModel()
    @State private var dragOffset: CGSize = .zero
    @State private var exitOffset: CGSize = .zero
    @State private var isExiting = false
    @State private var selectedListing: Listing?
    @State private var isLoadingEnrichment = true
    @State private var noEligibleListings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            if isLoadingEnrichment {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("物件データを読み込み中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if noEligibleListings {
                VStack(spacing: 16) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("画像付きの新着物件はありません")
                        .font(.headline)
                    Text("外観写真と間取り図が揃った物件のみ表示しています")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("閉じる") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                }
                .padding()
            } else if viewModel.isComplete {
                SwipeCompletionView(
                    likedCount: viewModel.likedCount,
                    nopedCount: viewModel.nopedCount,
                    skippedCount: viewModel.skippedCount,
                    likedListings: viewModel.likedListings,
                    onSelectListing: { selectedListing = $0 },
                    onDismiss: onDismiss
                )
            } else {
                cardStack
                Spacer()
                SwipeActionBar(
                    onNope: { animateSwipe(.nope) },
                    onSkip: { animateSwipe(.skip) },
                    onUndo: { guard !isExiting else { return }; viewModel.undo() },
                    onLike: { animateSwipe(.like) },
                    canUndo: viewModel.canUndo && !isExiting
                )
            }
            Spacer()
        }
        .background(Color(.systemGroupedBackground))
        .task {
            viewModel.loadCards(from: listings)
            await prefetchEnrichment()
            viewModel.filterCardsWithoutImages()
            noEligibleListings = viewModel.cards.isEmpty
            isLoadingEnrichment = false
        }
        .sheet(item: $selectedListing) { listing in
            ListingDetailView(listing: listing)
        }
        .accessibilityAction(named: "Like") { animateSwipe(.like) }
        .accessibilityAction(named: "Nope") { animateSwipe(.nope) }
        .accessibilityAction(named: "スキップ") { animateSwipe(.skip) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button("あとで") { onDismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !viewModel.cards.isEmpty {
                    Text("\(viewModel.currentIndex + (viewModel.isComplete ? 0 : 1)) / \(viewModel.cards.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            ProgressView(value: viewModel.progress)
                .tint(.accentColor)
                .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    // MARK: - Card Stack

    private var cardStack: some View {
        ZStack {
            ForEach(visibleCardIndices.reversed(), id: \.self) { index in
                let offset = index - viewModel.currentIndex
                let card = viewModel.cards[index]
                let isTop = offset == 0

                SwipeCardView(
                    listing: card,
                    dragOffset: isTop ? effectiveOffset : .zero,
                    isTopCard: isTop
                )
                .id(card.identityKey)
                .scaleEffect(scaleFor(offset: offset))
                .offset(y: CGFloat(offset) * 8)
                .offset(x: isTop ? effectiveOffset.width : 0,
                        y: isTop ? effectiveOffset.height : 0)
                .rotationEffect(isTop && !reduceMotion
                    ? .degrees(Double(effectiveOffset.width) / 20)
                    : .zero)
                .zIndex(Double(viewModel.cards.count - offset))
                .allowsHitTesting(isTop)
                .gesture(isTop ? dragGesture : nil)
                .onTapGesture {
                    if isTop { selectedListing = card }
                }
                .animation(
                    reduceMotion
                        ? .easeOut(duration: 0.2)
                        : .spring(response: 0.4, dampingFraction: 0.8),
                    value: viewModel.currentIndex
                )
            }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(min(viewModel.currentIndex + 1, viewModel.cards.count)) / \(viewModel.cards.count)")
    }

    private var visibleCardIndices: [Int] {
        let start = viewModel.currentIndex
        let end = min(start + 3, viewModel.cards.count)
        guard start < end else { return [] }
        return Array(start..<end)
    }

    private func scaleFor(offset: Int) -> CGFloat {
        switch offset {
        case 0: 1.0
        case 1: 0.95
        default: 0.90
        }
    }

    // MARK: - Drag Gesture

    private var effectiveOffset: CGSize {
        isExiting ? exitOffset : dragOffset
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isExiting else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isExiting else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let velocityX = value.predictedEndTranslation.width
                let threshold: CGFloat = UIScreen.main.bounds.width * 0.35
                let skipThreshold: CGFloat = 150

                if horizontal > threshold || velocityX > 500 {
                    commitWithAnimation(.like, translation: value.predictedEndTranslation)
                } else if horizontal < -threshold || velocityX < -500 {
                    commitWithAnimation(.nope, translation: value.predictedEndTranslation)
                } else if vertical > skipThreshold {
                    commitWithAnimation(.skip, translation: CGSize(width: 0, height: 600))
                } else {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func animateSwipe(_ decision: SwipeDecision) {
        guard !isExiting else { return }
        let target: CGSize
        switch decision {
        case .like:
            target = CGSize(width: UIScreen.main.bounds.width * 1.5, height: 0)
        case .nope:
            target = CGSize(width: -UIScreen.main.bounds.width * 1.5, height: 0)
        case .skip:
            target = CGSize(width: 0, height: 600)
        }
        commitWithAnimation(decision, translation: target)
    }

    private func commitWithAnimation(_ decision: SwipeDecision, translation: CGSize) {
        isExiting = true
        let exitAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.35, dampingFraction: 0.75)

        withAnimation(exitAnimation) {
            exitOffset = translation
        } completion: {
            viewModel.commitSwipe(decision)
            dragOffset = .zero
            exitOffset = .zero
            isExiting = false
        }
    }

    // MARK: - Enrichment Prefetch

    private func prefetchEnrichment() async {
        let store = SupabaseListingStore.shared
        let staleThreshold = Calendar.current.date(byAdding: .hour, value: -6, to: Date()) ?? .distantPast
        let needsFetch = SwipeSessionViewModel.listingsNeedingEnrichmentFetch(
            viewModel.cards, staleThreshold: staleThreshold
        )
        guard !needsFetch.isEmpty else { return }

        for listing in needsFetch {
            try? await store.fetchDetail(
                identityKey: listing.identityKey,
                modelContext: modelContext
            )
        }
    }
}
