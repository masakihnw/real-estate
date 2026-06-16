import Foundation
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "SwipeSession")

enum SwipeDecision {
    case like, nope, skip
}

@MainActor @Observable
final class SwipeSessionViewModel {
    private(set) var cards: [Listing] = []
    private(set) var currentIndex = 0
    private(set) var swipeResults: [(listing: Listing, decision: SwipeDecision)] = []
    private(set) var undoStack: [(listing: Listing, decision: SwipeDecision)] = []
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private let progressStore: SwipeProgressStore
    private let preferenceStore: any SwipePreferenceStoring

    init(
        progressStore: SwipeProgressStore = .shared,
        preferenceStore: any SwipePreferenceStoring = BuildingPreferenceStore.shared
    ) {
        self.progressStore = progressStore
        self.preferenceStore = preferenceStore
    }

    var isComplete: Bool { currentIndex >= cards.count }
    var currentCard: Listing? { cards.indices.contains(currentIndex) ? cards[currentIndex] : nil }
    var progress: Double { cards.isEmpty ? 0 : Double(currentIndex) / Double(cards.count) }
    var canUndo: Bool { !undoStack.isEmpty }

    var likedCount: Int { swipeResults.filter { $0.decision == .like }.count }
    var nopedCount: Int { swipeResults.filter { $0.decision == .nope }.count }
    var skippedCount: Int { swipeResults.filter { $0.decision == .skip }.count }

    var likedListings: [Listing] { swipeResults.filter { $0.decision == .like }.map(\.listing) }

    func loadCards(from allListings: [Listing]) {
        let prefStore = preferenceStore
        cards = allListings
            .filter { $0.propertyType == "chuko" && $0.isRecentlyAdded && !$0.isDelisted }
            .filter(GradeVisibility.isVisible)   // D評価は発見導線に出さない
            .filter { !prefStore.isBuildingReviewed($0) }
            .sorted { ($0.listingScore ?? 0) > ($1.listingScore ?? 0) }
        currentIndex = 0
        swipeResults = []
        undoStack = []
        pendingTasks.values.forEach { $0.cancel() }
        pendingTasks = [:]
        logger.info("Loaded \(self.cards.count) cards for swipe session")
    }

    func commitSwipe(_ decision: SwipeDecision) {
        guard let card = currentCard else { return }
        swipeResults.append((card, decision))
        undoStack.append((card, decision))
        currentIndex += 1

        // デッキ並び替え（skip/remaining）は端末ローカル状態なので identityKey を使う。
        // like/nope の永続化は端末再計算で不安定な identityKey ではなく、サーバー安定キー
        // preferenceKey を使う（再表示バグの根本対策）。
        let deckKey = card.identityKey
        let prefKey = card.preferenceKey
        switch decision {
        case .skip:
            // 「あとで」: 次回デッキの先頭に再登場させる
            if !progressStore.skippedKeys.contains(deckKey) {
                progressStore.skippedKeys.append(deckKey)
            }
            logger.info("Skipped: \(card.name, privacy: .public)")
        case .like, .nope:
            // 確定したら「あとで」リストから外す
            progressStore.skippedKeys.removeAll { $0 == deckKey }
            let pref: BuildingPreferenceStore.Preference = decision == .like ? .like : .nope
            pendingTasks[prefKey] = Task { [preferenceStore] in
                await preferenceStore.setPreference(prefKey, preference: pref)
            }
            logger.info("\(decision == .like ? "Liked" : "Noped", privacy: .public): \(card.name, privacy: .public)")
        }

        // 残りデッキの永続化は commitSwipe 内で同期的に行う（exit アニメ完了に従属させない）
        persistRemaining()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        swipeResults.removeLast()
        currentIndex -= 1

        let deckKey = last.listing.identityKey
        let prefKey = last.listing.preferenceKey
        pendingTasks[prefKey]?.cancel()
        pendingTasks.removeValue(forKey: prefKey)

        if last.decision == .skip {
            // 直前の skip を取り消す
            progressStore.skippedKeys.removeAll { $0 == deckKey }
        } else {
            Task { [preferenceStore] in
                await preferenceStore.removePreference(prefKey)
            }
            // 注: like/nope の取り消しでは、その物件が前回 skip 由来だった場合でも
            // skippedKeys へは戻さない（直前1手の取り消しという undo の責務を超えるため）。
            // eligible 内に留まるのでデッキからは消えず、新規扱いに降格するのみ。
        }
        persistRemaining()
        logger.info("Undid swipe on: \(last.listing.name, privacy: .public)")
    }

    /// 現在の未消化デッキを永続化する。完走時は残りをクリアする。
    private func persistRemaining() {
        if isComplete {
            progressStore.clearRemaining()
        } else {
            progressStore.remainingKeys = cards[currentIndex...].map(\.identityKey)
        }
    }

    /// prefetchEnrichment 完了後に呼ぶ。外観写真+間取り図がない物件を除外する。
    /// loadCards() が先に呼ばれて currentIndex/swipeResults がリセット済みであることを前提とする。
    func filterCardsWithoutImages() {
        let beforeImages = cards.count
        cards = cards.filter { $0.hasSwipeableImages }
        let afterImages = cards.count
        // 同一建物の重複（同名・別住戸／別ソースの住所粒度違いなど）を1枚に集約する。
        // 画像フィルタの後に行うことで、画像のある住戸を代表として残す
        // （cards は loadCards で listingScore 降順のため、先頭＝最良スコアが残る）。
        // 注: Brillia↔ブリリア のような表記揺れは buildingGroupKey が別建物扱いのため
        //     ここでは集約されない（名寄せ/正規化の別対応が必要）。
        var seenBuildings = Set<String>()
        cards = cards.filter { seenBuildings.insert($0.buildingGroupKey).inserted }
        let afterDedup = cards.count
        if afterDedup < beforeImages {
            logger.info("Pruned cards: \(beforeImages - afterImages) no-image, \(afterImages - afterDedup) duplicate building, \(afterDedup) remaining")
        }
    }

    /// filterCardsWithoutImages() の後に呼ぶ。保存済み進捗でデッキを再構成する。
    /// 画像剪定後の実デッキを eligible として SwipeDeckBuilder に渡すことで、
    /// build の入力と永続化対象（commitSwipe 時の cards）の対称性を保つ。
    /// 「あとで」キーは eligible 内に剪定して1回だけ再保存する。
    func restoreDeckOrder() {
        let eligibleKeys = Set(cards.map(\.identityKey))
        let prunedSkipped = progressStore.skippedKeys.filter { eligibleKeys.contains($0) }
        cards = SwipeDeckBuilder.build(
            eligible: cards,
            savedRemainingKeys: progressStore.remainingKeys,
            skippedKeys: prunedSkipped
        )
        currentIndex = 0
        progressStore.skippedKeys = prunedSkipped
        progressStore.remainingKeys = cards.map(\.identityKey)
        logger.info("Restored deck order: \(self.cards.count) cards, \(prunedSkipped.count) skipped re-surfaced")
    }

    /// enrichment の再フェッチが必要な物件を判定する。
    /// - 未フェッチ（enrichmentFetchedAt == nil）
    /// - 画像なしで前回フェッチから staleThreshold 以降経過（サーバー側で画像が後追い追加された可能性）
    static func listingsNeedingEnrichmentFetch(_ listings: [Listing], staleThreshold: Date) -> [Listing] {
        listings.filter { listing in
            if listing.enrichmentFetchedAt == nil { return true }
            if !listing.hasSwipeableImages,
               let fetched = listing.enrichmentFetchedAt,
               fetched < staleThreshold { return true }
            return false
        }
    }

    #if DEBUG
    func setCardsForTesting(_ listings: [Listing]) {
        cards = listings
        currentIndex = 0
        swipeResults = []
        undoStack = []
        pendingTasks.values.forEach { $0.cancel() }
        pendingTasks = [:]
    }
    #endif

    static func pendingCount(from listings: [Listing]) -> Int {
        let prefStore = BuildingPreferenceStore.shared
        var seenBuildings = Set<String>()
        return listings
            .filter { $0.propertyType == "chuko" && $0.isRecentlyAdded && !$0.isDelisted }
            .filter(GradeVisibility.isVisible)   // デッキ(loadCards)と件数を一致させる
            .filter { $0.hasFloorPlanImagesServer && $0.hasPropertyImagesServer }
            .filter { !prefStore.isBuildingReviewed($0) }
            // デッキ(filterCardsWithoutImages)と同様に同一建物の重複を1件に集約して数える。
            .filter { seenBuildings.insert($0.buildingGroupKey).inserted }
            .count
    }
}
