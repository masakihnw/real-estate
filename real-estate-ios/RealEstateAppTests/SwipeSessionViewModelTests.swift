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
        propertyType: String = "chuko",
        suumoImagesJSON: String? = nil,
        floorPlanImagesJSON: String? = nil,
        hasFloorPlanImagesServer: Bool = false,
        hasPropertyImagesServer: Bool = false
    ) -> Listing {
        SwipeSessionViewModelTests.counter += 1
        let unique = "\(name)_\(SwipeSessionViewModelTests.counter)_\(UUID().uuidString.prefix(8))"
        return Listing(
            url: "https://test.example.com/\(unique)",
            name: unique,
            floorPlanImagesJSON: floorPlanImagesJSON,
            suumoImagesJSON: suumoImagesJSON,
            addedAt: addedAt,
            isDelisted: isDelisted,
            propertyType: propertyType,
            listingScore: listingScore,
            hasFloorPlanImagesServer: hasFloorPlanImagesServer,
            hasPropertyImagesServer: hasPropertyImagesServer
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

    @Test("pendingCount は isRecentlyAdded かつ画像あり かつ未判定の物件数を返す")
    @MainActor
    func pendingCountFilters() {
        let listings = [
            makeListing(name: "新着1", addedAt: recentDate(daysAgo: 0), hasFloorPlanImagesServer: true, hasPropertyImagesServer: true),
            makeListing(name: "新着2", addedAt: recentDate(daysAgo: 1), hasFloorPlanImagesServer: true, hasPropertyImagesServer: true),
            makeListing(name: "古い", addedAt: recentDate(daysAgo: 5), hasFloorPlanImagesServer: true, hasPropertyImagesServer: true),
            makeListing(name: "掲載終了", addedAt: recentDate(daysAgo: 0), isDelisted: true, hasFloorPlanImagesServer: true, hasPropertyImagesServer: true),
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

    // MARK: - hasSwipeableImages

    @Test("hasSwipeableImages: 外観写真と間取り図の両方あり → true")
    func hasSwipeableImagesBothPresent() {
        let listing = makeListing(
            name: "画像あり",
            suumoImagesJSON: #"[{"url":"https://example.com/img.jpg","label":"外観"}]"#,
            floorPlanImagesJSON: #"["https://example.com/floor.jpg"]"#
        )
        #expect(listing.hasSwipeableImages)
    }

    @Test("hasSwipeableImages: 外観写真のみ → false")
    func hasSwipeableImagesOnlySuumo() {
        let listing = makeListing(
            name: "外観のみ",
            suumoImagesJSON: #"[{"url":"https://example.com/img.jpg","label":"外観"}]"#
        )
        #expect(!listing.hasSwipeableImages)
    }

    @Test("hasSwipeableImages: 間取り図のみ → false")
    func hasSwipeableImagesOnlyFloorPlan() {
        let listing = makeListing(
            name: "間取りのみ",
            floorPlanImagesJSON: #"["https://example.com/floor.jpg"]"#
        )
        #expect(!listing.hasSwipeableImages)
    }

    @Test("hasSwipeableImages: 両方なし → false")
    func hasSwipeableImagesNeither() {
        let listing = makeListing(name: "画像なし")
        #expect(!listing.hasSwipeableImages)
    }

    @Test("hasSwipeableImages: 空配列 → false")
    func hasSwipeableImagesEmptyArrays() {
        let listing = makeListing(
            name: "空配列",
            suumoImagesJSON: "[]",
            floorPlanImagesJSON: "[]"
        )
        #expect(!listing.hasSwipeableImages)
    }

    // MARK: - filterCardsWithoutImages

    @Test("filterCardsWithoutImages は画像のない物件を除外する")
    @MainActor
    func filterCardsWithoutImagesRemovesImageless() {
        let vm = SwipeSessionViewModel()
        let withImages = makeListing(
            name: "画像あり",
            suumoImagesJSON: #"[{"url":"https://example.com/img.jpg","label":"外観"}]"#,
            floorPlanImagesJSON: #"["https://example.com/floor.jpg"]"#
        )
        let noImages = makeListing(name: "画像なし")
        let onlySuumo = makeListing(
            name: "外観のみ",
            suumoImagesJSON: #"[{"url":"https://example.com/img.jpg","label":"外観"}]"#
        )
        vm.setCardsForTesting([withImages, noImages, onlySuumo])
        #expect(vm.cards.count == 3)

        vm.filterCardsWithoutImages()
        #expect(vm.cards.count == 1)
        #expect(vm.cards[0].name == withImages.name)
    }

    @Test("filterCardsWithoutImages は全物件に画像があれば何も除外しない")
    @MainActor
    func filterCardsWithoutImagesKeepsAll() {
        let vm = SwipeSessionViewModel()
        let a = makeListing(
            name: "A",
            suumoImagesJSON: #"[{"url":"https://a.com/1.jpg","label":"外観"}]"#,
            floorPlanImagesJSON: #"["https://a.com/fp.jpg"]"#
        )
        let b = makeListing(
            name: "B",
            suumoImagesJSON: #"[{"url":"https://b.com/1.jpg","label":"リビング"}]"#,
            floorPlanImagesJSON: #"["https://b.com/fp.jpg"]"#
        )
        vm.setCardsForTesting([a, b])
        vm.filterCardsWithoutImages()
        #expect(vm.cards.count == 2)
    }

    @Test("filterCardsWithoutImages で全物件除外されると cards が空になる")
    @MainActor
    func filterCardsWithoutImagesAllFiltered() {
        let vm = SwipeSessionViewModel()
        let noImages1 = makeListing(name: "なし1")
        let noImages2 = makeListing(name: "なし2")
        vm.setCardsForTesting([noImages1, noImages2])
        vm.filterCardsWithoutImages()
        #expect(vm.cards.isEmpty)
        #expect(vm.isComplete)
    }

    // MARK: - listingsNeedingEnrichmentFetch

    @Test("未フェッチ（enrichmentFetchedAt == nil）の物件は再フェッチ対象")
    @MainActor
    func needsFetchWhenNeverFetched() {
        let listing = makeListing(name: "未フェッチ")
        let threshold = Date().addingTimeInterval(-6 * 3600)
        let result = SwipeSessionViewModel.listingsNeedingEnrichmentFetch([listing], staleThreshold: threshold)
        #expect(result.count == 1)
    }

    @Test("画像あり+フェッチ済みの物件は再フェッチ不要")
    @MainActor
    func noRefetchWhenImagesPresent() {
        let listing = makeListing(
            name: "画像あり",
            suumoImagesJSON: #"[{"url":"https://example.com/img.jpg","label":"外観"}]"#,
            floorPlanImagesJSON: #"["https://example.com/floor.jpg"]"#
        )
        listing.enrichmentFetchedAt = Date().addingTimeInterval(-3600)
        let threshold = Date().addingTimeInterval(-6 * 3600)
        let result = SwipeSessionViewModel.listingsNeedingEnrichmentFetch([listing], staleThreshold: threshold)
        #expect(result.isEmpty)
    }

    @Test("画像なし+フェッチから6時間以上経過 → 再フェッチ対象")
    @MainActor
    func refetchWhenNoImagesAndStale() {
        let listing = makeListing(name: "画像なし古い")
        listing.enrichmentFetchedAt = Date().addingTimeInterval(-7 * 3600)
        let threshold = Date().addingTimeInterval(-6 * 3600)
        let result = SwipeSessionViewModel.listingsNeedingEnrichmentFetch([listing], staleThreshold: threshold)
        #expect(result.count == 1)
    }

    @Test("画像なし+フェッチから6時間未満 → 再フェッチ不要")
    @MainActor
    func noRefetchWhenNoImagesButRecent() {
        let listing = makeListing(name: "画像なし新しい")
        listing.enrichmentFetchedAt = Date().addingTimeInterval(-3600)
        let threshold = Date().addingTimeInterval(-6 * 3600)
        let result = SwipeSessionViewModel.listingsNeedingEnrichmentFetch([listing], staleThreshold: threshold)
        #expect(result.isEmpty)
    }

    // MARK: - pendingCount (サーバー画像フラグ)

    @Test("pendingCount: サーバーフラグが両方 true の物件のみカウントする")
    @MainActor
    func pendingCountFiltersServerImageFlags() {
        let withBoth = makeListing(
            name: "両方あり",
            hasFloorPlanImagesServer: true,
            hasPropertyImagesServer: true
        )
        let noFloorPlan = makeListing(
            name: "間取りなし",
            hasPropertyImagesServer: true
        )
        let noProperty = makeListing(
            name: "外観なし",
            hasFloorPlanImagesServer: true
        )
        let neither = makeListing(name: "両方なし")
        let count = SwipeSessionViewModel.pendingCount(
            from: [withBoth, noFloorPlan, noProperty, neither]
        )
        #expect(count == 1)
    }

    @Test("pendingCount: 全物件に画像フラグありなら全カウント")
    @MainActor
    func pendingCountAllWithImages() {
        let a = makeListing(name: "A", hasFloorPlanImagesServer: true, hasPropertyImagesServer: true)
        let b = makeListing(name: "B", hasFloorPlanImagesServer: true, hasPropertyImagesServer: true)
        let count = SwipeSessionViewModel.pendingCount(from: [a, b])
        #expect(count == 2)
    }

    @Test("pendingCount: 古い物件と delisted は除外される")
    @MainActor
    func pendingCountExcludesOldAndDelisted() {
        let recent = makeListing(
            name: "新着",
            hasFloorPlanImagesServer: true,
            hasPropertyImagesServer: true
        )
        let old = makeListing(
            name: "古い",
            addedAt: recentDate(daysAgo: 5),
            hasFloorPlanImagesServer: true,
            hasPropertyImagesServer: true
        )
        let delisted = makeListing(
            name: "終了",
            isDelisted: true,
            hasFloorPlanImagesServer: true,
            hasPropertyImagesServer: true
        )
        let count = SwipeSessionViewModel.pendingCount(from: [recent, old, delisted])
        #expect(count == 1)
    }
}
