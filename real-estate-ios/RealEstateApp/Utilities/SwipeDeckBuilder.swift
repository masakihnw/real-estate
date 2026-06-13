import Foundation

/// スワイプデッキの並び順を構築する純関数。
///
/// 並び順（§3.5）:
/// 1. 前回「あとで」した物件（skippedKeys の順）— 次回デッキの先頭に再登場
/// 2. 前回セッションの残り（savedRemainingKeys の順）— 続きから再開
/// 3. 新規（listingScore 降順）
///
/// eligible に含まれない保存キー（評価済み・掲載終了等）は黙って除外される。
/// 同一物件が複数グループに該当する場合は先勝ち（skip が最優先）。
enum SwipeDeckBuilder {

    static func build(
        eligible: [Listing],
        savedRemainingKeys: [String] = [],
        skippedKeys: [String] = []
    ) -> [Listing] {
        guard !savedRemainingKeys.isEmpty || !skippedKeys.isEmpty else {
            return sortByScore(eligible)
        }

        let byKey = Dictionary(
            eligible.map { ($0.identityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var deck: [Listing] = []
        var used = Set<String>()

        for key in skippedKeys {
            guard let listing = byKey[key], used.insert(key).inserted else { continue }
            deck.append(listing)
        }
        for key in savedRemainingKeys {
            guard let listing = byKey[key], used.insert(key).inserted else { continue }
            deck.append(listing)
        }
        let fresh = eligible.filter { !used.contains($0.identityKey) }
        deck.append(contentsOf: sortByScore(fresh))
        return deck
    }

    private static func sortByScore(_ listings: [Listing]) -> [Listing] {
        listings.sorted { ($0.listingScore ?? 0) > ($1.listingScore ?? 0) }
    }
}
