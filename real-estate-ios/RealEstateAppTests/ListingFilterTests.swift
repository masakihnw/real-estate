//
//  ListingFilterTests.swift
//  RealEstateAppTests
//
//  ListingFilter の述語仕様を固定する特性テスト（refactor Phase 1 安全網）。
//  既存挙動をそのまま検証し、実装は変更しない。
//

import Testing
import Foundation
@testable import RealEstateApp

@Suite("ListingFilter")
struct ListingFilterTests {

    private func makeListing(
        url: String = "https://example.com/1",
        name: String = "パークタワー晴海",
        priceMan: Int? = 9800,
        address: String? = "東京都中央区晴海2丁目3-1",
        walkMin: Int? = 5,
        areaM2: Double? = 70.5,
        layout: String? = "3LDK",
        totalUnits: Int? = 1084,
        ownership: String? = "所有権",
        managementFee: Int? = nil,
        repairReserveFund: Int? = nil,
        direction: String? = nil
    ) -> Listing {
        Listing(
            url: url,
            name: name,
            priceMan: priceMan,
            address: address,
            walkMin: walkMin,
            areaM2: areaM2,
            layout: layout,
            totalUnits: totalUnits,
            ownership: ownership,
            managementFee: managementFee,
            repairReserveFund: repairReserveFund,
            direction: direction
        )
    }

    // MARK: - extractWard

    @Test("住所から区名を抽出する")
    func extractWardFromTokyoAddress() {
        #expect(ListingFilter.extractWard(from: "東京都江東区豊洲5丁目") == "江東区")
        #expect(ListingFilter.extractWard(from: "東京都中央区晴海2丁目3-1") == "中央区")
    }

    @Test("県の市名も抽出する")
    func extractWardFromCityAddress() {
        #expect(ListingFilter.extractWard(from: "神奈川県川崎市中原区") == "川崎市")
    }

    @Test("nil・形式外の住所は nil")
    func extractWardReturnsNilForInvalid() {
        #expect(ListingFilter.extractWard(from: nil) == nil)
        #expect(ListingFilter.extractWard(from: "晴海2丁目") == nil)
    }

    // MARK: - AIグレード（発見導線フィルタ）

    private func makeGraded(_ grade: String?, listingScore: Int? = nil, isLiked: Bool = false) -> Listing {
        let key = grade ?? "nil"
        return Listing(
            url: "https://example.com/grade-\(key)-\(UUID().uuidString.prefix(6))",
            name: "物件\(key)",
            priceMan: 5000,
            isLiked: isLiked,
            listingScore: listingScore,
            assetGrade: grade
        )
    }

    @Test("apply は D評価を除外し、S/A/B/C・未分析は通す")
    func applyExcludesGradeD() {
        let filter = ListingFilter()
        let listings = [
            makeGraded("S"), makeGraded("A"), makeGraded("B"),
            makeGraded("C"), makeGraded("D"), makeGraded(nil),
        ]
        let result = filter.apply(to: listings)
        let grades = result.map { $0.assetGrade ?? "nil" }
        #expect(!grades.contains("D"))
        #expect(grades.contains("nil"))   // 未分析はフェイルセーフで表示
        #expect(result.count == 5)
    }

    @Test("apply はいいね済みの D評価を残す")
    func applyKeepsLikedGradeD() {
        let filter = ListingFilter()
        let likedD = makeGraded("D", isLiked: true)
        let result = filter.apply(to: [likedD])
        #expect(result.map(\.identityKey) == [likedD.identityKey])
    }

    // MARK: - 価格フィルタ

    @Test("価格帯フィルタは範囲内のみ通す")
    func priceRangeFilters() {
        var filter = ListingFilter()
        filter.priceMin = 9000
        filter.priceMax = 10000
        let inRange = makeListing(url: "https://example.com/a", priceMan: 9800)
        let tooLow = makeListing(url: "https://example.com/b", priceMan: 8000)
        let tooHigh = makeListing(url: "https://example.com/c", priceMan: 12000)
        let result = filter.apply(to: [inRange, tooLow, tooHigh])
        #expect(result.map(\.url) == ["https://example.com/a"])
    }

    @Test("価格未定は includePriceUndecided=true なら価格帯指定があっても通す")
    func priceUndecidedIncludedByDefault() {
        var filter = ListingFilter()
        filter.priceMin = 9000
        let undecided = makeListing(url: "https://example.com/u", priceMan: nil)
        let result = filter.apply(to: [undecided])
        #expect(result.count == 1)
    }

    @Test("includePriceUndecided=false なら価格未定を除外する")
    func priceUndecidedExcludedWhenDisabled() {
        var filter = ListingFilter()
        filter.includePriceUndecided = false
        let undecided = makeListing(url: "https://example.com/u", priceMan: nil)
        let priced = makeListing(url: "https://example.com/p", priceMan: 9800)
        let result = filter.apply(to: [undecided, priced])
        #expect(result.map(\.url) == ["https://example.com/p"])
    }

    // MARK: - 間取り・区・徒歩・面積

    @Test("間取りフィルタは選択した間取りのみ通す")
    func layoutFilter() {
        var filter = ListingFilter()
        filter.layouts = ["3LDK"]
        let a = makeListing(url: "https://example.com/a", layout: "3LDK")
        let b = makeListing(url: "https://example.com/b", layout: "2LDK")
        let c = makeListing(url: "https://example.com/c", layout: nil)
        let result = filter.apply(to: [a, b, c])
        #expect(result.map(\.url) == ["https://example.com/a"])
    }

    @Test("区フィルタは住所から抽出した区名で判定する")
    func wardFilter() {
        var filter = ListingFilter()
        filter.wards = ["中央区"]
        let chuo = makeListing(url: "https://example.com/a", address: "東京都中央区晴海2丁目")
        let koto = makeListing(url: "https://example.com/b", address: "東京都江東区豊洲5丁目")
        let noAddr = makeListing(url: "https://example.com/c", address: nil)
        let result = filter.apply(to: [chuo, koto, noAddr])
        #expect(result.map(\.url) == ["https://example.com/a"])
    }

    @Test("徒歩分数フィルタは walk_min 不明(nil)を 99 扱いで除外する")
    func walkMaxTreatsNilAs99() {
        var filter = ListingFilter()
        filter.walkMax = 10
        let near = makeListing(url: "https://example.com/a", walkMin: 5)
        let far = makeListing(url: "https://example.com/b", walkMin: 15)
        let unknown = makeListing(url: "https://example.com/c", walkMin: nil)
        let result = filter.apply(to: [near, far, unknown])
        #expect(result.map(\.url) == ["https://example.com/a"])
    }

    @Test("面積フィルタは面積不明(nil)を 0 扱いで除外する")
    func areaMinTreatsNilAsZero() {
        var filter = ListingFilter()
        filter.areaMin = 60
        let large = makeListing(url: "https://example.com/a", areaM2: 70.5)
        let small = makeListing(url: "https://example.com/b", areaM2: 55.0)
        let unknown = makeListing(url: "https://example.com/c", areaM2: nil)
        let result = filter.apply(to: [large, small, unknown])
        #expect(result.map(\.url) == ["https://example.com/a"])
    }

    // MARK: - 権利形態・向き

    @Test("権利形態は部分一致で判定する（定期借地権 → 借地）")
    func ownershipFilterMatchesSubstring() {
        var filter = ListingFilter()
        filter.ownershipTypes = [.leasehold]
        let leasehold = makeListing(url: "https://example.com/a", ownership: "定期借地権")
        let owned = makeListing(url: "https://example.com/b", ownership: "所有権")
        let result = filter.apply(to: [leasehold, owned])
        #expect(result.map(\.url) == ["https://example.com/a"])
    }

    @Test("向きフィルタは向き不明を除外する")
    func directionFilterExcludesNil() {
        var filter = ListingFilter()
        filter.directions = ["南"]
        let south = makeListing(url: "https://example.com/a", direction: "南")
        let north = makeListing(url: "https://example.com/b", direction: "北")
        let unknown = makeListing(url: "https://example.com/c", direction: nil)
        let result = filter.apply(to: [south, north, unknown])
        #expect(result.map(\.url) == ["https://example.com/a"])
    }

    // MARK: - 数値レンジフィルタ

    @Test("数値フィルタは min/max 範囲で絞り、値なしは除外する")
    func numericRangeFilter() {
        var filter = ListingFilter()
        filter.numericFilters[.totalUnits] = ListingNumericRange(min: 100, max: 2000)
        let big = makeListing(url: "https://example.com/a", totalUnits: 1084)
        let small = makeListing(url: "https://example.com/b", totalUnits: 20)
        let unknown = makeListing(url: "https://example.com/c", totalUnits: nil)
        let result = filter.apply(to: [big, small, unknown])
        #expect(result.map(\.url) == ["https://example.com/a"])
    }

    // MARK: - 月額支払フィルタ

    @Test("月額支払フィルタはローン+管理費+修繕積立金の合計で判定する")
    func monthlyPaymentFilter() {
        var generous = ListingFilter()
        generous.monthlyPaymentMax = 100  // 100万円/月: 9800万でも余裕で通る
        var tight = ListingFilter()
        tight.monthlyPaymentMax = 1      // 1万円/月: 通らない
        let listing = makeListing(
            url: "https://example.com/a",
            priceMan: 9800,
            managementFee: 20_000,
            repairReserveFund: 15_000
        )
        #expect(generous.apply(to: [listing]).count == 1)
        #expect(tight.apply(to: [listing]).isEmpty)
    }

    // MARK: - isActive / reset

    @Test("デフォルトは inactive、条件を足すと active、reset で戻る")
    func isActiveAndReset() {
        var filter = ListingFilter()
        #expect(!filter.isActive)
        filter.walkMax = 10
        #expect(filter.isActive)
        filter.reset()
        #expect(!filter.isActive)
    }

    @Test("includePriceUndecided を false にしただけでも active になる")
    func excludingUndecidedIsActive() {
        var filter = ListingFilter()
        filter.includePriceUndecided = false
        #expect(filter.isActive)
    }

    // MARK: - 選択肢ヘルパー

    @Test("availableLayouts は重複なしソート済み")
    func availableLayoutsSortedUnique() {
        let listings = [
            makeListing(url: "https://example.com/a", layout: "3LDK"),
            makeListing(url: "https://example.com/b", layout: "2LDK"),
            makeListing(url: "https://example.com/c", layout: "3LDK"),
            makeListing(url: "https://example.com/d", layout: nil),
        ]
        #expect(ListingFilter.availableLayouts(from: listings) == ["2LDK", "3LDK"])
    }

    @Test("availableWards は住所から区名を集約する")
    func availableWardsCollected() {
        let listings = [
            makeListing(url: "https://example.com/a", address: "東京都中央区晴海2丁目"),
            makeListing(url: "https://example.com/b", address: "東京都江東区豊洲5丁目"),
            makeListing(url: "https://example.com/c", address: nil),
        ]
        #expect(ListingFilter.availableWards(from: listings) == ["中央区", "江東区"])
    }
}
