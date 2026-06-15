import Testing
@testable import RealEstateApp

@Suite("SwipeSessionView.visibleWindow")
struct SwipeVisibleWindowTests {

    @Test("先頭ではトップ＋次の2枚をマウントする")
    func mountsTopAndNext() {
        #expect(SwipeSessionView.visibleWindow(currentIndex: 0, count: 10) == [0, 1])
    }

    @Test("中間でもトップ＋次の2枚")
    func mountsTwoInMiddle() {
        #expect(SwipeSessionView.visibleWindow(currentIndex: 5, count: 10) == [5, 6])
    }

    @Test("最後のカードではトップ1枚のみ（次がない）")
    func lastCardMountsOne() {
        #expect(SwipeSessionView.visibleWindow(currentIndex: 9, count: 10) == [9])
    }

    @Test("全カード消化後は空")
    func completedIsEmpty() {
        #expect(SwipeSessionView.visibleWindow(currentIndex: 10, count: 10) == [])
    }

    @Test("カードが0件なら空")
    func emptyDeck() {
        #expect(SwipeSessionView.visibleWindow(currentIndex: 0, count: 0) == [])
    }

    @Test("maxMounted を増やすとプリロード枚数が増える")
    func customMaxMounted() {
        #expect(SwipeSessionView.visibleWindow(currentIndex: 0, count: 10, maxMounted: 3) == [0, 1, 2])
    }

    @Test("maxMounted がデッキ末尾を超えても範囲内に収まる")
    func clampsToCount() {
        #expect(SwipeSessionView.visibleWindow(currentIndex: 8, count: 10, maxMounted: 3) == [8, 9])
    }
}
