import Testing
import Foundation
@testable import RealEstateApp

@Suite("HeatmapBucketer 成約ヒートマップ集約")
struct HeatmapBucketerTests {

    private func input(_ ward: String, _ price: Int, lat: Double = 35.6, lon: Double = 139.7) -> HeatmapBucketer.Input {
        .init(ward: ward, m2Price: price, latitude: lat, longitude: lon)
    }

    @Test("区ごとに平均㎡単価・件数・重心を集計")
    func aggregatesByWard() {
        let buckets = HeatmapBucketer.buckets(from: [
            input("港区", 2_000_000, lat: 35.66, lon: 139.75),
            input("港区", 2_200_000, lat: 35.68, lon: 139.73),
            input("足立区", 600_000, lat: 35.77, lon: 139.80),
        ])
        let minato = buckets.first { $0.ward == "港区" }!
        #expect(minato.avgM2Price == 2_100_000)
        #expect(minato.count == 2)
        #expect(abs(minato.centerLatitude - 35.67) < 0.001)
        #expect(buckets.count == 2)
    }

    @Test("平均価格の順位で level（安い=0 … 高い=levelCount-1）")
    func levelByPercentile() {
        // 5区を価格昇順で → level 0,1,2,3,4 に均等割当
        let buckets = HeatmapBucketer.buckets(from: [
            input("A", 100), input("B", 200), input("C", 300), input("D", 400), input("E", 500),
        ])
        let byWard = Dictionary(uniqueKeysWithValues: buckets.map { ($0.ward, $0.level) })
        #expect(byWard["A"] == 0)
        #expect(byWard["E"] == HeatmapBucketer.levelCount - 1)
        #expect(byWard["A"]! < byWard["C"]!)
        #expect(byWard["C"]! < byWard["E"]!)
    }

    @Test("絶対値でなく順位ベース（全区が高額でも段は分かれる）")
    func relativeNotAbsolute() {
        // 全て高額だが相対順位で段が割れる
        let buckets = HeatmapBucketer.buckets(from: [
            input("X", 1_900_000), input("Y", 2_000_000), input("Z", 2_100_000),
        ])
        let levels = Set(buckets.map(\.level))
        #expect(levels.count >= 2)   // 全部同じ段にならない
    }

    @Test("区が1つだけなら level=0")
    func singleWard() {
        let buckets = HeatmapBucketer.buckets(from: [input("港区", 1_000_000), input("港区", 1_200_000)])
        #expect(buckets.count == 1)
        #expect(buckets[0].level == 0)
        #expect(buckets[0].avgM2Price == 1_100_000)
    }

    @Test("ward が空のレコードは除外")
    func excludesEmptyWard() {
        let buckets = HeatmapBucketer.buckets(from: [input("", 999), input("港区", 1_000_000)])
        #expect(buckets.count == 1)
        #expect(buckets[0].ward == "港区")
    }

    @Test("空入力は空配列")
    func emptyInput() {
        #expect(HeatmapBucketer.buckets(from: []).isEmpty)
    }
}
