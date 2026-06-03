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

    var isComplete: Bool { currentIndex >= cards.count }
    var currentCard: Listing? { cards.indices.contains(currentIndex) ? cards[currentIndex] : nil }
    var progress: Double { cards.isEmpty ? 0 : Double(currentIndex) / Double(cards.count) }
    var canUndo: Bool { !undoStack.isEmpty }

    var likedCount: Int { swipeResults.filter { $0.decision == .like }.count }
    var nopedCount: Int { swipeResults.filter { $0.decision == .nope }.count }
    var skippedCount: Int { swipeResults.filter { $0.decision == .skip }.count }

    var likedListings: [Listing] { swipeResults.filter { $0.decision == .like }.map(\.listing) }

    func loadCards(from allListings: [Listing]) {
        let prefStore = BuildingPreferenceStore.shared
        cards = allListings
            .filter { $0.propertyType == "chuko" && $0.isRecentlyAdded && !$0.isDelisted }
            .filter { !prefStore.isLiked($0.identityKey) && !prefStore.isNoped($0.identityKey) }
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

        guard decision != .skip else {
            logger.info("Skipped: \(card.name, privacy: .public)")
            return
        }

        let key = card.identityKey
        let pref: BuildingPreferenceStore.Preference = decision == .like ? .like : .nope
        pendingTasks[key] = Task {
            await BuildingPreferenceStore.shared.setPreference(key, preference: pref)
        }
        logger.info("\(decision == .like ? "Liked" : "Noped", privacy: .public): \(card.name, privacy: .public)")
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        swipeResults.removeLast()
        currentIndex -= 1

        let key = last.listing.identityKey
        pendingTasks[key]?.cancel()
        pendingTasks.removeValue(forKey: key)

        if last.decision != .skip {
            Task {
                await BuildingPreferenceStore.shared.removePreference(key)
            }
        }
        logger.info("Undid swipe on: \(last.listing.name, privacy: .public)")
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
        return listings
            .filter { $0.propertyType == "chuko" && $0.isRecentlyAdded && !$0.isDelisted }
            .filter { !prefStore.isLiked($0.identityKey) && !prefStore.isNoped($0.identityKey) }
            .count
    }
}
