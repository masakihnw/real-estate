import Foundation
import WidgetKit

/// ウィジェットへ渡す共有データ。
///
/// 注意: 同じ JSON 形状を RealEstateWidget/RealEstateWidget.swift の `WidgetData` が
/// 手動で持つ（別ターゲットのため型共有不可）。フィールド名・型を変えたら両方そろえる。
/// 既存 widget バイナリとの互換のため、追加フィールドは optional にする。
struct WidgetPayload: Codable {
    let totalListings: Int
    let newListings: Int
    let likedCount: Int
    let lastUpdated: Date
    let priceChanges: Int
    let likedSummaries: [LikedSummary]
    /// 「今日の1枚」候補。先頭が small、先頭2件が medium 用。空/欠落なら counts にフォールバック。
    /// optional は旧 JSON（キー欠落）との decode 互換のため。
    var featuredItems: [Featured]?
    /// AIデイリーブリーフ1文（medium 用）。当日分のみ。
    var briefText: String?

    struct LikedSummary: Codable {
        let name: String
        let priceMan: Int?
        let priceChange: Int?
    }

    struct Featured: Codable {
        let url: String          // ディープリンク識別子（listing.url）
        let name: String
        let priceText: String
        let gradeLetter: String?
        let isNew: Bool
        /// App Group コンテナ内の画像ファイル名。未取得なら nil（no-image レイアウト）。
        let imageFileName: String?
    }
}

enum WidgetDataProvider {
    static let suiteName = "group.com.hanawa.realestate"
    static let dataKey = "widgetData"

    /// brief の更新方針。背景更新では前景で書いた brief を潰さないよう `.keep` を使う。
    enum BriefUpdate {
        case keep            // 既存の briefText を据え置く
        case set(String?)    // 明示的に設定（nil で消去）
    }

    static func update(
        totalListings: Int,
        newListings: Int,
        likedCount: Int,
        priceChanges: Int,
        likedSummaries: [(name: String, priceMan: Int?, priceChange: Int?)],
        featuredItems: [WidgetPayload.Featured],
        brief: BriefUpdate
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }

        let briefText: String?
        switch brief {
        case .keep:
            briefText = loadExisting(from: defaults)?.briefText
        case .set(let text):
            briefText = text
        }

        let payload = WidgetPayload(
            totalListings: totalListings,
            newListings: newListings,
            likedCount: likedCount,
            lastUpdated: .now,
            priceChanges: priceChanges,
            likedSummaries: likedSummaries.map {
                WidgetPayload.LikedSummary(name: $0.name, priceMan: $0.priceMan, priceChange: $0.priceChange)
            },
            featuredItems: featuredItems,
            briefText: briefText
        )

        guard let encoded = try? JSONEncoder().encode(payload) else { return }
        defaults.set(encoded, forKey: dataKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func loadExisting(from defaults: UserDefaults) -> WidgetPayload? {
        guard let data = defaults.data(forKey: dataKey) else { return nil }
        return try? JSONDecoder().decode(WidgetPayload.self, from: data)
    }
}
