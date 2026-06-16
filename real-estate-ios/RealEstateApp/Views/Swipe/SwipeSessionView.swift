import SwiftUI
import UIKit

struct SwipeSessionView: View {
    let listings: [Listing]
    let onDismiss: () -> Void

    @State private var viewModel = SwipeSessionViewModel()
    @State private var dragOffset: CGSize = .zero
    @State private var exitOffset: CGSize = .zero
    @State private var isExiting = false
    /// ボタン/ジェスチャ確定時にスタンプを確実に表示する（特に skip の「あとで」）
    @State private var forcedStamp: SwipeDecision?
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
                    emptyStateDiagnostic   // 件数は出るのにデッキ空、の原因確認用（常設）
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
                    onUndo: {
                        guard !isExiting else { return }
                        HapticManager.soft()
                        viewModel.undo()
                    },
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
            // 画像剪定後の実デッキで保存済み進捗を復元（順序を確定してから空判定）
            viewModel.restoreDeckOrder()
            noEligibleListings = viewModel.cards.isEmpty
            isLoadingEnrichment = false
        }
        .sheet(item: $selectedListing) { listing in
            ListingDetailView(listing: listing)
        }
        .accessibilityAction(named: "Like") { animateSwipe(.like) }
        .accessibilityAction(named: "Nope") { animateSwipe(.nope) }
        .accessibilityAction(named: "あとで") { animateSwipe(.skip) }
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
                    isTopCard: isTop,
                    forcedStamp: isTop ? forcedStamp : nil
                )
                .id(card.identityKey)
                // 画面に見えるのは常にトップ1枚だけ。次カードはプリロード目的でマウントするが
                // 通常時は非表示にする（カード高さが AI 分析の有無で変わり背面がはみ出す問題を防ぐ）。
                // exit アニメ中だけ直後のカードを背面に出し、トップが飛ぶと下から現れる演出にする。
                .opacity(cardOpacity(isTop: isTop, offset: offset))
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
        Self.visibleWindow(currentIndex: viewModel.currentIndex, count: viewModel.cards.count)
    }

    /// カードの不透明度。表示するのはトップ1枚のみ。
    /// exit アニメ中だけ直後のカード（offset==1）を背面に出し、トップが飛んだ後の
    /// めくれ演出にする（通常時は非表示なので高さ可変でもはみ出さない）。
    private func cardOpacity(isTop: Bool, offset: Int) -> Double {
        if isTop { return 1 }
        if offset == 1 && isExiting { return 1 }
        return 0
    }

    /// マウントするカードのインデックス範囲。
    /// 画面に表示するのはトップ1枚のみだが、次カードの画像をプリロードするため
    /// トップ＋次の計 `maxMounted` 枚をマウントする（背面カードは `opacity(0)` で非表示）。
    static func visibleWindow(currentIndex: Int, count: Int, maxMounted: Int = 2) -> [Int] {
        let start = max(0, currentIndex)
        let end = min(start + max(1, maxMounted), count)
        guard start < end else { return [] }
        return Array(start..<end)
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
        // ボタン・ジェスチャ両経路で確定時に1回だけ発火（SwipeActionBar 側の直書きは廃止）
        HapticManager.impact(decision == .nope ? .medium : .light)
        // exit アニメ中にスタンプを確実に表示（skip の「あとで」は dragOffset 駆動では出ないため）
        forcedStamp = decision
        let exitAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.35, dampingFraction: 0.75)

        withAnimation(exitAnimation) {
            exitOffset = translation
        } completion: {
            viewModel.commitSwipe(decision)
            dragOffset = .zero
            exitOffset = .zero
            forcedStamp = nil
            isExiting = false
        }
    }

    // MARK: - Empty-state Diagnostic（件数は出るのにデッキ空、の原因可視化・常設デバッグ）

    /// pendingCount が数えるのにデッキに出ない物件を、状態付きで列挙する。
    private var countedListingDiagnostics: [String] {
        let prefStore = BuildingPreferenceStore.shared
        let counted = listings
            .filter { $0.propertyType == "chuko" && $0.isRecentlyAdded && !$0.isDelisted }
            .filter(GradeVisibility.isVisible)
            .filter { $0.countsAsSwipeableForBadge }
            .filter { !prefStore.isBuildingReviewed($0) }
        return counted.map { l in
            "・\(l.name.prefix(16)) | fetched:\(l.enrichmentFetchedAt != nil ? "Y" : "N") swipe:\(l.hasSwipeableImages ? "Y" : "N") (suumo:\(l.hasSuumoImages ? "Y" : "N") floor:\(l.hasFloorPlanImages ? "Y" : "N")) srv(P:\(l.hasPropertyImagesServer ? "Y" : "N") F:\(l.hasFloorPlanImagesServer ? "Y" : "N")) rev:\(prefStore.isBuildingReviewed(l) ? "Y" : "N") sbKey:\(l.supabaseIdentityKey == nil ? "nil" : "set")"
        }
    }

    @ViewBuilder
    private var emptyStateDiagnostic: some View {
        let diags = countedListingDiagnostics
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DEBUG: 件数に数えられている \(diags.count) 件")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Spacer()
                Button {
                    UIPasteboard.general.string = diags.joined(separator: "\n")
                    HapticManager.success()
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(diags.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 12)
    }

    // MARK: - Enrichment Prefetch

    private func prefetchEnrichment() async {
        let staleThreshold = Calendar.current.date(byAdding: .hour, value: -6, to: Date()) ?? .distantPast
        let needsFetch = SwipeSessionViewModel.listingsNeedingEnrichmentFetch(
            viewModel.cards, staleThreshold: staleThreshold
        )
        guard !needsFetch.isEmpty else { return }

        // ネットワーク取得（重い get_listing_detail）を上限付きで並列実行する。
        // 直列だと eligible 件数ぶん RPC を1件ずつ待つため起動ローディングが長かった。
        // SwiftData(ModelContext) は MainActor で逐次反映し、ネットワークだけ並列化する。
        let byKey: [String: Listing] = Dictionary(
            needsFetch.map { ($0.supabaseIdentityKey ?? $0.identityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let keys = needsFetch.map { $0.supabaseIdentityKey ?? $0.identityKey }
        let maxConcurrent = 6
        var nextIndex = 0
        var didChange = false

        await withTaskGroup(of: (String, ListingDTO?, Bool).self) { group in
            func addTask(_ key: String) {
                group.addTask {
                    do {
                        let dto = try await SupabaseListingStore.shared.fetchDetailDTO(identityKey: key)
                        return (key, dto, true)   // 取得成功（dto が nil でも「試行済み」）
                    } catch {
                        return (key, nil, false)  // 通信エラー＝未試行扱い（次回再取得）
                    }
                }
            }
            while nextIndex < keys.count && nextIndex < maxConcurrent {
                addTask(keys[nextIndex]); nextIndex += 1
            }
            for await (key, dto, succeeded) in group {
                if succeeded, let listing = byKey[key] {
                    if let dto, let incoming = Listing.from(dto: dto, fetchedAt: Date()) {
                        SupabaseListingStore.updateEnrichmentFields(listing, from: incoming)
                    }
                    // 取得試行済みを記録（画像が載らない物件が件数に残り続けるのを防ぐ）。
                    if listing.enrichmentFetchedAt == nil {
                        listing.enrichmentFetchedAt = Date()
                    }
                    didChange = true
                }
                if nextIndex < keys.count {
                    addTask(keys[nextIndex]); nextIndex += 1
                }
            }
        }
        if didChange { try? modelContext.save() }
    }
}
