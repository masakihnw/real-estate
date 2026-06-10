import Foundation

/// 比較表の差分強調ロジック。
///
/// 各行の数値から「最良」「最劣」のインデックスを判定する。
/// View から分離してユニットテスト可能にする。
enum ComparisonHighlight {
    /// 最良値のインデックス。非nil値が2件未満、または全て同値なら nil（強調しない）。
    static func bestIndex(_ values: [Double?], higherIsBetter: Bool) -> Int? {
        extremeIndex(values, pickHigher: higherIsBetter)
    }

    /// 最劣値のインデックス。非nil値が2件未満、または全て同値なら nil。
    static func worstIndex(_ values: [Double?], higherIsBetter: Bool) -> Int? {
        extremeIndex(values, pickHigher: !higherIsBetter)
    }

    private static func extremeIndex(_ values: [Double?], pickHigher: Bool) -> Int? {
        let present = values.enumerated().compactMap { idx, v in v.map { (idx, $0) } }
        guard present.count >= 2 else { return nil }
        guard Set(present.map(\.1)).count >= 2 else { return nil }
        let target = pickHigher
            ? present.max(by: { $0.1 < $1.1 })
            : present.min(by: { $0.1 < $1.1 })
        guard let target else { return nil }
        // 同値の極値が複数ある場合は強調しない（どれが最良か曖昧なため）
        let count = present.filter { $0.1 == target.1 }.count
        return count == 1 ? target.0 : nil
    }
}
