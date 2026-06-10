import Foundation

/// 価格履歴の統計分析。
///
/// 詳細画面の価格変動セクションに「値下げ頻度・平均間隔・トレンド判定」を
/// 表示するための計算ロジック。View から分離してユニットテスト可能にする。
struct PriceTrendAnalysis: Equatable {
    enum Trend: String {
        case rapidDiscount = "急速値下げ"      // 平均間隔 14日以内で値下げが継続
        case gradualDiscount = "段階的値下げ"  // 値下げ傾向（間隔は緩やか）
        case stable = "値動きなし"
        case increased = "値上げ傾向"
        case mixed = "上下混在"
    }

    /// 値下げ回数
    let dropCount: Int
    /// 値上げ回数
    let raiseCount: Int
    /// 価格変更の平均間隔（日）。変更が1回以下なら nil
    let avgDaysBetweenChanges: Int?
    /// 初値からの累計変動率（%）。初値が取れない場合は nil
    let totalChangePct: Double?
    /// トレンド判定
    let trend: Trend

    /// 急速値下げとみなす平均間隔の閾値（日）
    static let rapidIntervalDays = 14

    init?(history: [Listing.PriceHistoryEntry]) {
        let entries = history.filter { $0.priceMan != nil }
        guard entries.count >= 2 else { return nil }

        var drops = 0
        var raises = 0
        var changeDates: [Date] = []
        for i in 1..<entries.count {
            guard let prev = entries[i - 1].priceMan, let cur = entries[i].priceMan,
                  prev != cur else { continue }
            if cur < prev { drops += 1 } else { raises += 1 }
            if let date = entries[i].parsedDate {
                changeDates.append(date)
            }
        }
        dropCount = drops
        raiseCount = raises

        // 平均間隔: 初回掲載日（先頭エントリ）から最後の変更日までを変更回数で割る
        if drops + raises >= 1,
           let firstDate = entries.first?.parsedDate,
           let lastChange = changeDates.last,
           lastChange > firstDate {
            let days = Calendar.current.dateComponents([.day], from: firstDate, to: lastChange).day ?? 0
            avgDaysBetweenChanges = max(1, days / (drops + raises))
        } else {
            avgDaysBetweenChanges = nil
        }

        if let first = entries.first?.priceMan, let last = entries.last?.priceMan, first > 0 {
            totalChangePct = Double(last - first) / Double(first) * 100
        } else {
            totalChangePct = nil
        }

        switch (drops, raises) {
        case (0, 0):
            trend = .stable
        case (let d, 0) where d > 0:
            if let interval = avgDaysBetweenChanges, interval <= Self.rapidIntervalDays {
                trend = .rapidDiscount
            } else {
                trend = .gradualDiscount
            }
        case (0, let r) where r > 0:
            trend = .increased
        default:
            trend = .mixed
        }
    }
}
