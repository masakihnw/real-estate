import Foundation

/// 日次スワイプカードの画像配列を構築する純ロジック。
///
/// View（`SwipeCardView`）の private メソッドに直接書かず、テスト可能な
/// ユーティリティへ抽出する（ECC: ロジックは View から切り出す）。
///
/// 並び順: メイン写真 → SUUMO 物件写真 → 間取り図。
/// あわせて「最初の間取り図」の index を返し、カード上の常時表示する
/// 間取り小窓（タップでカルーセルを間取り図へジャンプ）の遷移先に使う。
enum SwipeCardImageBuilder {

    /// カード1枚に表示する画像。
    struct CardImage: Identifiable, Equatable {
        let url: URL
        let label: String
        /// 間取り図か（小窓・ラベル表示の判定に使う）。
        let isFloorPlan: Bool
        var id: String { url.absoluteString }
    }

    /// 構築結果。`images` の並びと、最初の間取り図の index を返す。
    struct Deck: Equatable {
        let images: [CardImage]
        /// 最初の間取り図画像の index（間取り小窓タップのジャンプ先）。なければ nil。
        let floorPlanIndex: Int?

        static let empty = Deck(images: [], floorPlanIndex: nil)
    }

    static let mainLabel = "メイン"
    static let floorPlanLabel = "間取り図"

    /// メイン写真 → SUUMO 物件写真 → 間取り図 の順に構築する。
    ///
    /// - サムネと同一 URL の SUUMO 写真は除外（先頭重複の防止。既存挙動を踏襲）。
    /// - 間取り図は重複排除の対象外。新着の仕分けで最重要のため、必ず全枚数を残す。
    static func build(
        thumbnailURL: URL?,
        suumoImages: [(url: URL, label: String)],
        floorPlanImages: [URL]
    ) -> Deck {
        var images: [CardImage] = []

        if let thumb = thumbnailURL {
            images.append(CardImage(url: thumb, label: mainLabel, isFloorPlan: false))
        }
        for img in suumoImages where img.url != thumbnailURL {
            images.append(CardImage(url: img.url, label: img.label, isFloorPlan: false))
        }

        var floorPlanIndex: Int?
        for url in floorPlanImages {
            if floorPlanIndex == nil { floorPlanIndex = images.count }
            images.append(CardImage(url: url, label: floorPlanLabel, isFloorPlan: true))
        }

        return Deck(images: images, floorPlanIndex: floorPlanIndex)
    }
}
