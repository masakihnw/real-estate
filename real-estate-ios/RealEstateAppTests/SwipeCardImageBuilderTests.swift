import Testing
import Foundation
@testable import RealEstateApp

/// 日次スワイプカードの画像構築ロジックのテスト。
///
/// 仕様: メイン写真 → SUUMO 物件写真 → 間取り図 の順に並べ、
/// 最初の間取り図 index を返す（カード上の間取り小窓のジャンプ先）。
@Suite("SwipeCardImageBuilder")
struct SwipeCardImageBuilderTests {

    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("メイン→物件写真→間取りの順に並び、間取り index を返す")
    func ordering() {
        let deck = SwipeCardImageBuilder.build(
            thumbnailURL: url("https://img/main.jpg"),
            suumoImages: [
                (url("https://img/living.jpg"), "リビング"),
                (url("https://img/kitchen.jpg"), "キッチン"),
            ],
            floorPlanImages: [url("https://img/floor.jpg")]
        )
        #expect(deck.images.map(\.label) == ["メイン", "リビング", "キッチン", "間取り図"])
        #expect(deck.floorPlanIndex == 3)
        #expect(deck.images[3].isFloorPlan)
        #expect(!deck.images[0].isFloorPlan)
    }

    @Test("サムネと同一 URL の SUUMO 写真は除外する（先頭重複防止）")
    func dedupThumbnail() {
        let main = url("https://img/main.jpg")
        let deck = SwipeCardImageBuilder.build(
            thumbnailURL: main,
            suumoImages: [
                (main, "外観"),                       // サムネと重複 → 除外
                (url("https://img/living.jpg"), "リビング"),
            ],
            floorPlanImages: [url("https://img/floor.jpg")]
        )
        #expect(deck.images.map(\.url) == [main, url("https://img/living.jpg"), url("https://img/floor.jpg")])
        #expect(deck.floorPlanIndex == 2)
    }

    @Test("間取り図がなければ floorPlanIndex は nil")
    func noFloorPlan() {
        let deck = SwipeCardImageBuilder.build(
            thumbnailURL: url("https://img/main.jpg"),
            suumoImages: [(url("https://img/living.jpg"), "リビング")],
            floorPlanImages: []
        )
        #expect(deck.floorPlanIndex == nil)
        #expect(deck.images.allSatisfy { !$0.isFloorPlan })
    }

    @Test("間取り図のみ（メイン・物件写真なし）なら index は 0")
    func onlyFloorPlan() {
        let deck = SwipeCardImageBuilder.build(
            thumbnailURL: nil,
            suumoImages: [],
            floorPlanImages: [url("https://img/floor.jpg")]
        )
        #expect(deck.images.count == 1)
        #expect(deck.floorPlanIndex == 0)
        #expect(deck.images[0].isFloorPlan)
    }

    @Test("間取り図が複数でも index は最初の1枚を指す")
    func multipleFloorPlans() {
        let deck = SwipeCardImageBuilder.build(
            thumbnailURL: url("https://img/main.jpg"),
            suumoImages: [],
            floorPlanImages: [url("https://img/floor1.jpg"), url("https://img/floor2.jpg")]
        )
        #expect(deck.floorPlanIndex == 1)
        #expect(deck.images.filter(\.isFloorPlan).count == 2)
    }

    @Test("画像が一切なければ空デッキ")
    func empty() {
        let deck = SwipeCardImageBuilder.build(thumbnailURL: nil, suumoImages: [], floorPlanImages: [])
        #expect(deck == SwipeCardImageBuilder.Deck.empty)
    }
}
