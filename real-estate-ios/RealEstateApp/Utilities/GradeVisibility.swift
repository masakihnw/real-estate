import Foundation

/// AI資産グレードによる「発見導線での表示可否」の単一判定。
///
/// プロダクト方針: AI分析の結果が最下位グレード（D）の物件は、発見導線
/// （物件一覧・地図・スワイプ・Today の変化カード/全件タイムライン・ホームウィジェット）に出さない。
///
/// View や各フィルタが個別に grade を解釈すると挙動がズレるため、
/// 判定は必ずこの実装を参照する（単一ソース）。
/// お気に入り / ウォッチリストなど「ユーザーが明示的に選んだ集合」には適用しない。
enum GradeVisibility {
    /// 発見導線で非表示にするグレード集合（大文字で保持）。
    /// グレードは S/A/B/C/D の5段階で、"D" が最下位（=「D以下」は実質 D のみ）。
    /// 比較時に `uppercased()` するため、サーバーが小文字を返しても取りこぼさない。
    static let hiddenGrades: Set<String> = ["D"]

    /// 発見導線に表示してよいか。
    ///
    /// フェイルセーフ方針:
    /// - グレード未付与（未分析・スコアも無い）は表示する。AI分析前の新着を誤って隠さない。
    /// - いいね済み（`isLiked`）は常に表示する。ユーザーが自分で選んだ物件は隠さない。
    static func isVisible(_ listing: Listing) -> Bool {
        if listing.isLiked { return true }
        guard let grade = listing.scoreGradeLetter else { return true }
        return !hiddenGrades.contains(grade.uppercased())
    }

    /// 発見導線に表示する物件だけに絞り込む（順序は保持）。
    static func visible(_ listings: [Listing]) -> [Listing] {
        listings.filter(isVisible)
    }
}
