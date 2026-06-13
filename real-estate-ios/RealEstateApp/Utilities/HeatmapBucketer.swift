import Foundation

/// 成約価格ヒートマップの集約バケット（区単位）。
struct HeatmapBucket: Identifiable {
    let ward: String
    /// 区内成約の代表座標（緯度経度の重心）
    let centerLatitude: Double
    let centerLongitude: Double
    /// 区内成約の平均 ㎡単価（円/㎡）
    let avgM2Price: Int
    let count: Int
    /// 色段（0 = 最も安い … levelCount-1 = 最も高い）。表示集合内のパーセンタイル順位で決まる。
    let level: Int

    var id: String { ward }
}

/// 成約レコードを区単位に集約し、パーセンタイル順位で色段を割り当てる純ロジック。
///
/// 絶対値の固定色域だと「足立区だけ表示→全部青／港区だけ→全部赤」になり判別不能なため、
/// 表示対象集合の順位ベース（パーセンタイル）で段を決める（提案 §3.4・方針レビュー M-3）。
/// MKMapView 描画から分離してテスト可能にする。
enum HeatmapBucketer {
    /// 色段数（緑→黄→赤の5段）
    static let levelCount = 5

    struct Input {
        let ward: String
        let m2Price: Int       // 円/㎡
        let latitude: Double
        let longitude: Double
    }

    /// 区ごとに平均㎡単価・重心・件数を集計し、平均価格の順位で level を割り当てる。
    /// ward が空のレコードは除外。区が1つだけなら level=0。
    static func buckets(from inputs: [Input]) -> [HeatmapBucket] {
        let grouped = Dictionary(grouping: inputs.filter { !$0.ward.isEmpty }, by: \.ward)
        guard !grouped.isEmpty else { return [] }

        // 区ごとの集計（平均価格・重心・件数）
        struct Agg { let ward: String; let avg: Int; let lat: Double; let lon: Double; let count: Int }
        var aggs: [Agg] = grouped.map { ward, records in
            let n = records.count
            let avg = records.reduce(0) { $0 + $1.m2Price } / n
            let lat = records.reduce(0.0) { $0 + $1.latitude } / Double(n)
            let lon = records.reduce(0.0) { $0 + $1.longitude } / Double(n)
            return Agg(ward: ward, avg: avg, lat: lat, lon: lon, count: n)
        }

        // 平均価格の昇順で順位 → パーセンタイル段（安い=0, 高い=levelCount-1）
        aggs.sort { $0.avg < $1.avg }
        let total = aggs.count
        return aggs.enumerated().map { index, agg in
            let level: Int
            if total <= 1 {
                level = 0
            } else {
                let ratio = Double(index) / Double(total - 1)   // 0...1
                level = min(levelCount - 1, Int(ratio * Double(levelCount - 1) + 0.5))
            }
            return HeatmapBucket(
                ward: agg.ward,
                centerLatitude: agg.lat,
                centerLongitude: agg.lon,
                avgM2Price: agg.avg,
                count: agg.count,
                level: level
            )
        }
    }
}
