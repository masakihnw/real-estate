//
//  HazardAdvisorTests.swift
//  RealEstateAppTests
//
//  HazardAdvisor の純粋ロジック特性テスト（refactor Phase 4 / D6）。
//  ListingDetailView から抽出したロジックの現挙動を固定する。
//

import Testing
import Foundation
@testable import RealEstateApp

@Suite("HazardAdvisor")
struct HazardAdvisorTests {

    // MARK: - buyerTips

    @Test("ハザードなしなら助言は空")
    func noHazardNoTips() {
        let hazard = Listing.HazardData()
        #expect(HazardAdvisor.buyerTips(for: hazard).isEmpty)
    }

    @Test("洪水・内水のいずれかで浸水助言を出す")
    func floodOrInlandWaterTip() {
        var flood = Listing.HazardData()
        flood.flood = true
        #expect(HazardAdvisor.buyerTips(for: flood).contains { $0.contains("浸水の直接被害") })

        var inland = Listing.HazardData()
        inland.inlandWater = true
        #expect(HazardAdvisor.buyerTips(for: inland).contains { $0.contains("浸水の直接被害") })
    }

    @Test("洪水と内水が両方該当でも浸水助言は1件のみ")
    func floodAndInlandWaterSingleTip() {
        var hazard = Listing.HazardData()
        hazard.flood = true
        hazard.inlandWater = true
        let floodTips = HazardAdvisor.buyerTips(for: hazard).filter { $0.contains("浸水の直接被害") }
        #expect(floodTips.count == 1)
    }

    @Test("液状化で杭基礎助言を出す")
    func liquefactionTip() {
        var hazard = Listing.HazardData()
        hazard.liquefaction = true
        #expect(HazardAdvisor.buyerTips(for: hazard).contains { $0.contains("杭基礎") })
    }

    @Test("建物倒壊ランク3以上で耐震助言、2以下では出さない")
    func buildingCollapseThreshold() {
        var rank3 = Listing.HazardData()
        rank3.buildingCollapse = 3
        #expect(HazardAdvisor.buyerTips(for: rank3).contains { $0.contains("新耐震") })

        var rank2 = Listing.HazardData()
        rank2.buildingCollapse = 2
        #expect(!HazardAdvisor.buyerTips(for: rank2).contains { $0.contains("新耐震") })
    }

    @Test("高潮で台風助言を出す")
    func stormSurgeTip() {
        var hazard = Listing.HazardData()
        hazard.stormSurge = true
        #expect(HazardAdvisor.buyerTips(for: hazard).contains { $0.contains("台風時の高潮") })
    }

    @Test("複数該当で助言が定義順に並ぶ")
    func multipleTipsInOrder() {
        var hazard = Listing.HazardData()
        hazard.flood = true
        hazard.liquefaction = true
        hazard.buildingCollapse = 4
        hazard.stormSurge = true
        let tips = HazardAdvisor.buyerTips(for: hazard)
        #expect(tips.count == 4)
        #expect(tips[0].contains("浸水の直接被害"))
        #expect(tips[1].contains("杭基礎"))
        #expect(tips[2].contains("新耐震"))
        #expect(tips[3].contains("台風時の高潮"))
    }

    // MARK: - rank(fromLabel:)

    @Test("ラベル末尾の数字をランクとして抽出する")
    func rankFromLabel() {
        #expect(HazardAdvisor.rank(fromLabel: "建物倒壊 ランク3") == 3)
        #expect(HazardAdvisor.rank(fromLabel: "総合5") == 5)
    }

    @Test("末尾が数字でなければ 0")
    func rankFallsBackToZero() {
        #expect(HazardAdvisor.rank(fromLabel: "建物倒壊") == 0)
        #expect(HazardAdvisor.rank(fromLabel: "") == 0)
    }
}
