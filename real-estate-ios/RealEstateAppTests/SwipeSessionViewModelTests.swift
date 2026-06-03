import Testing
import Foundation
@testable import RealEstateApp

@Suite("SwipeSessionViewModel")
struct SwipeSessionViewModelTests {

    // MARK: - Helpers

    private nonisolated(unsafe) static var counter = 0

    private func makeListing(
        name: String,
        addedAt: Date = Date(),
        isDelisted: Bool = false,
        listingScore: Int? = nil,
        propertyType: String = "chuko"
    ) -> Listing {
        SwipeSessionViewModelTests.counter += 1
        let unique = "\(name)_\(SwipeSessionViewModelTests.counter)_\(UUID().uuidString.prefix(8))"
        return Listing(
            url: "https://test.example.com/\(unique)",
            name: unique,
            addedAt: addedAt,
            isDelisted: isDelisted,
            propertyType: propertyType,
            listingScore: listingScore
        )
    }

    private func recentDate(daysAgo: Int = 0) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
    }

    @MainActor
    private func vmWithCards(_ count: Int) -> SwipeSessionViewModel {
        let vm = SwipeSessionViewModel()
        let listings = (0..<count).map { i in makeListing(name: "card\(i)") }
        vm.setCardsForTesting(listings)
        return vm
    }

    // MARK: - loadCards filtering

    @Test("loadCards は isRecentlyAdded かつ !isDelisted の物件のみ含む")
    @MainActor
    func loadCardsFiltersCorrectly() {
        let vm = SwipeSessionViewModel()
        let today = makeListing(name: "今日", addedAt: recentDate(daysAgo: 0))
        let yesterday = makeListing(name: "昨日", addedAt: recentDate(daysAgo: 1))
        let old = makeListing(name: "古い", addedAt: recentDate(daysAgo: 5))
        let delisted = makeListing(name: "終了", addedAt: recentDate(daysAgo: 0), isDelisted: true)
        vm.loadCards(from: [today, yesterday, old, delisted])
        #expect(vm.cards.count == 2)
        #expect(!vm.cards.contains(where: { $0.name == old.name }))
        #expect(!vm.cards.contains(where: { $0.name == delisted.name }))
    }

    @Test("loadCards は新築（shinchiku）を除外する")
    @MainActor
    func loadCardsExcludesShinchiku() {
        let vm = SwipeSessionViewModel()
        let chuko = makeListing(name: "中古物件")
        let shinchiku = makeListing(name: "新築物件", propertyType: "shinchiku")
        vm.loadCards(from: [chuko, shinchiku])
        #expect(vm.cards.count == 1)
        #expect(vm.cards[0].name == chuko.name)
    }

    @Test("loadCards は listingScore 降順でソートする")
    @MainActor
    func loadCardsSortsByScore() {
        let vm = SwipeSessionViewModel()
        let low = makeListing(name: "低", listingScore: 30)
        let high = makeListing(name: "高", listingScore: 80)
        let mid = makeListing(name: "中", listingScore: 55)
        vm.loadCards(from: [low, high, mid])
        #expect(vm.cards[0].name == high.name)
        #expect(vm.cards[1].name == mid.name)
        #expect(vm.cards[2].name == low.name)
    }

    @Test("loadCards で空の配列を渡すと cards は空")
    @MainActor
    func loadCardsEmpty() {
        let vm = SwipeSessionViewModel()
        vm.loadCards(from: [])
        #expect(vm.cards.isEmpty)
        #expect(vm.isComplete)
    }

    // MARK: - Initial State

    @Test("初期状態のプロパティが正しい")
    @MainActor
    func initialState() {
        let vm = SwipeSessionViewModel()
        #expect(vm.cards.isEmpty)
        #expect(vm.currentCard == nil)
        #expect(vm.isComplete)
        #expect(vm.progress == 0)
        #expect(vm.likedCount == 0)
        #expect(vm.nopedCount == 0)
        #expect(vm.skippedCount == 0)
        #expect(!vm.canUndo)
    }

    // MARK: - commitSwipe

    @Test("commitSwipe(.like) で currentIndex が進み likedCount が増える")
    @MainActor
    func commitLike() {
        let vm = vmWithCards(2)
        let secondName = vm.cards[1].name
        vm.commitSwipe(.like)
        #expect(vm.likedCount == 1)
        #expect(vm.nopedCount == 0)
        #expect(vm.currentCard?.name == secondName)
    }

    @Test("commitSwipe(.nope) で nopedCount が増える")
    @MainActor
    func commitNope() {
        let vm = vmWithCards(2)
        vm.commitSwipe(.nope)
        #expect(vm.nopedCount == 1)
        #expect(vm.likedCount == 0)
    }

    @Test("commitSwipe(.skip) で skippedCount が増える")
    @MainActor
    func commitSkip() {
        let vm = vmWithCards(2)
        vm.commitSwipe(.skip)
        #expect(vm.skippedCount == 1)
        #expect(vm.likedCount == 0)
        #expect(vm.nopedCount == 0)
    }

    @Test("全カードスワイプ後に isComplete が true")
    @MainActor
    func completionAfterAllSwipes() {
        let vm = vmWithCards(2)
        vm.commitSwipe(.like)
        #expect(!vm.isComplete)
        vm.commitSwipe(.nope)
        #expect(vm.isComplete)
        #expect(vm.currentCard == nil)
    }

    @Test("currentCard が nil のとき commitSwipe は何もしない")
    @MainActor
    func commitSwipeOnEmpty() {
        let vm = SwipeSessionViewModel()
        vm.commitSwipe(.like)
        #expect(vm.likedCount == 0)
    }

    // MARK: - progress

    @Test("progress は currentIndex / cards.count を返す")
    @MainActor
    func progressTracking() {
        let vm = vmWithCards(4)
        #expect(vm.progress == 0)
        vm.commitSwipe(.like)
        #expect(vm.progress == 0.25)
        vm.commitSwipe(.nope)
        #expect(vm.progress == 0.5)
        vm.commitSwipe(.skip)
        #expect(vm.progress == 0.75)
        vm.commitSwipe(.like)
        #expect(vm.progress == 1.0)
    }

    // MARK: - undo

    @Test("undo で直前のスワイプが取り消され index が戻る")
    @MainActor
    func undoRevertsLastSwipe() {
        let vm = vmWithCards(2)
        let firstName = vm.cards[0].name
        let secondName = vm.cards[1].name
        vm.commitSwipe(.like)
        #expect(vm.currentCard?.name == secondName)
        vm.undo()
        #expect(vm.currentCard?.name == firstName)
        #expect(vm.likedCount == 0)
        #expect(!vm.canUndo)
    }

    @Test("undo は canUndo == false のとき何もしない")
    @MainActor
    func undoWhenEmpty() {
        let vm = vmWithCards(1)
        let name = vm.cards[0].name
        vm.undo()
        #expect(vm.currentCard?.name == name)
    }

    @Test("skip の undo は index を戻すだけ")
    @MainActor
    func undoSkip() {
        let vm = vmWithCards(2)
        let firstName = vm.cards[0].name
        vm.commitSwipe(.skip)
        #expect(vm.skippedCount == 1)
        vm.undo()
        #expect(vm.skippedCount == 0)
        #expect(vm.currentCard?.name == firstName)
    }

    @Test("連続 undo は1つずつ巻き戻す")
    @MainActor
    func multipleUndos() {
        let vm = vmWithCards(3)
        let names = vm.cards.map(\.name)
        vm.commitSwipe(.like)
        vm.commitSwipe(.nope)
        vm.commitSwipe(.skip)
        #expect(vm.isComplete)
        vm.undo()
        #expect(vm.currentCard?.name == names[2])
        #expect(vm.skippedCount == 0)
        vm.undo()
        #expect(vm.currentCard?.name == names[1])
        #expect(vm.nopedCount == 0)
        vm.undo()
        #expect(vm.currentCard?.name == names[0])
        #expect(vm.likedCount == 0)
        #expect(!vm.canUndo)
    }

    // MARK: - likedListings

    @Test("likedListings は Like した物件だけを返す")
    @MainActor
    func likedListingsFilter() {
        let vm = vmWithCards(3)
        let names = vm.cards.map(\.name)
        vm.commitSwipe(.like)
        vm.commitSwipe(.nope)
        vm.commitSwipe(.like)
        #expect(vm.likedListings.map(\.name) == [names[0], names[2]])
    }

    // MARK: - pendingCount

    @Test("pendingCount は isRecentlyAdded かつ未判定の物件数を返す")
    @MainActor
    func pendingCountFilters() {
        let listings = [
            makeListing(name: "新着1", addedAt: recentDate(daysAgo: 0)),
            makeListing(name: "新着2", addedAt: recentDate(daysAgo: 1)),
            makeListing(name: "古い", addedAt: recentDate(daysAgo: 5)),
            makeListing(name: "掲載終了", addedAt: recentDate(daysAgo: 0), isDelisted: true),
        ]
        let count = SwipeSessionViewModel.pendingCount(from: listings)
        #expect(count >= 2)
    }

    // MARK: - setCardsForTesting resets state

    @Test("setCardsForTesting で状態がリセットされる")
    @MainActor
    func setCardsResetsState() {
        let vm = vmWithCards(2)
        vm.commitSwipe(.like)
        #expect(vm.likedCount == 1)

        let newCard = makeListing(name: "新しい")
        vm.setCardsForTesting([newCard])
        #expect(vm.likedCount == 0)
        #expect(vm.currentCard?.name == newCard.name)
        #expect(!vm.canUndo)
    }

    // MARK: - Rapid Swipe (連続スワイプ)

    @Test("連続スワイプで正しくカウントが進む")
    @MainActor
    func rapidSwipeUpdatesCorrectly() {
        let vm = vmWithCards(5)
        vm.commitSwipe(.like)
        vm.commitSwipe(.nope)
        vm.commitSwipe(.like)
        vm.commitSwipe(.skip)
        vm.commitSwipe(.nope)
        #expect(vm.isComplete)
        #expect(vm.likedCount == 2)
        #expect(vm.nopedCount == 2)
        #expect(vm.skippedCount == 1)
    }

    @Test("連続スワイプ後の連続 undo で全て元に戻る")
    @MainActor
    func rapidSwipeThenFullUndo() {
        let vm = vmWithCards(3)
        let firstName = vm.cards[0].name
        vm.commitSwipe(.like)
        vm.commitSwipe(.nope)
        vm.commitSwipe(.skip)
        #expect(vm.isComplete)

        vm.undo()
        vm.undo()
        vm.undo()
        #expect(vm.currentCard?.name == firstName)
        #expect(vm.likedCount == 0)
        #expect(vm.nopedCount == 0)
        #expect(vm.skippedCount == 0)
        #expect(!vm.canUndo)
    }
}
