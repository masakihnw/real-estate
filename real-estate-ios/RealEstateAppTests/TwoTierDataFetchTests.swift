import Testing
import Foundation
@testable import RealEstateApp

@Suite("2層データ取得: update() の nil-coalescing と enrichment 更新")
struct TwoTierDataFetchTests {

    // MARK: - Helpers

    private func makeListing(
        url: String = "https://suumo.jp/test/1",
        name: String = "テストマンション",
        hazardInfo: String? = nil,
        ssRadarData: String? = nil,
        ssPastMarketTrends: String? = nil,
        ssSurroundingProperties: String? = nil,
        ssPriceJudgments: String? = nil,
        reinfolibMarketData: String? = nil,
        mansionReviewData: String? = nil,
        estatPopulationData: String? = nil,
        priceHistoryJSON: String? = nil,
        altSourcesJSON: String? = nil,
        investmentSummary: String? = nil,
        extractedFeaturesJSON: String? = nil,
        imageCategoriesJSON: String? = nil,
        dedupCandidatesJSON: String? = nil,
        floorPlanImagesJSON: String? = nil,
        suumoImagesJSON: String? = nil,
        aiRecommendationSummary: String? = nil,
        aiRecommendationFlagsJSON: String? = nil,
        aiRecommendationAction: String? = nil,
        commuteInfoJSON: String? = nil,
        commuteInfoV2JSON: String? = nil,
        ssLookupStatus: String? = nil,
        ssProfitPct: Int? = nil,
        enrichmentFetchedAt: Date? = nil
    ) -> Listing {
        let l = Listing(
            url: url,
            name: name,
            hazardInfo: hazardInfo,
            commuteInfoJSON: commuteInfoJSON,
            commuteInfoV2JSON: commuteInfoV2JSON,
            ssLookupStatus: ssLookupStatus,
            ssProfitPct: ssProfitPct,
            ssRadarData: ssRadarData,
            ssPastMarketTrends: ssPastMarketTrends,
            ssSurroundingProperties: ssSurroundingProperties,
            ssPriceJudgments: ssPriceJudgments,
            reinfolibMarketData: reinfolibMarketData,
            mansionReviewData: mansionReviewData,
            estatPopulationData: estatPopulationData,
            priceHistoryJSON: priceHistoryJSON,
            altSourcesJSON: altSourcesJSON,
            investmentSummary: investmentSummary,
            extractedFeaturesJSON: extractedFeaturesJSON,
            imageCategoriesJSON: imageCategoriesJSON,
            dedupCandidatesJSON: dedupCandidatesJSON,
            aiRecommendationSummary: aiRecommendationSummary,
            aiRecommendationFlagsJSON: aiRecommendationFlagsJSON,
            aiRecommendationAction: aiRecommendationAction
        )
        l.floorPlanImagesJSON = floorPlanImagesJSON
        l.suumoImagesJSON = suumoImagesJSON
        l.enrichmentFetchedAt = enrichmentFetchedAt
        return l
    }

    // MARK: - update() nil-coalescing: 軽量ビュー同期でキャッシュが消えないこと

    @Test("軽量同期: enrichment nil の new で既存の enrichment JSONB が保持される")
    func lightSyncPreservesEnrichment() {
        let existing = makeListing(
            hazardInfo: "{\"flood\":\"low\"}",
            ssRadarData: "{\"score\":85}",
            reinfolibMarketData: "{\"avg_price\":5000}",
            mansionReviewData: "{\"rating\":4.2}",
            estatPopulationData: "{\"pop\":12000}",
            priceHistoryJSON: "[{\"date\":\"2025-01\",\"price\":5000}]",
            altSourcesJSON: "[{\"source\":\"homes\",\"url\":\"https://homes.jp/1\"}]",
            investmentSummary: "{\"roi\":3.5}",
            extractedFeaturesJSON: "[\"南向き\",\"角部屋\"]",
            imageCategoriesJSON: "{\"exterior\":[\"img1.jpg\"]}",
            dedupCandidatesJSON: "[\"key2\"]",
            floorPlanImagesJSON: "[\"plan1.jpg\"]",
            suumoImagesJSON: "[\"suumo1.jpg\"]",
            aiRecommendationSummary: "おすすめ物件",
            aiRecommendationFlagsJSON: "{\"is_recommended\":true}",
            aiRecommendationAction: "買い"
        )

        let lightNew = makeListing(name: "テストマンション更新")

        ListingStore.shared.updateFromSupabase(existing, from: lightNew)

        #expect(existing.name == "テストマンション更新")
        #expect(existing.hazardInfo == "{\"flood\":\"low\"}")
        #expect(existing.ssRadarData == "{\"score\":85}")
        #expect(existing.reinfolibMarketData == "{\"avg_price\":5000}")
        #expect(existing.mansionReviewData == "{\"rating\":4.2}")
        #expect(existing.estatPopulationData == "{\"pop\":12000}")
        #expect(existing.priceHistoryJSON == "[{\"date\":\"2025-01\",\"price\":5000}]")
        #expect(existing.altSourcesJSON == "[{\"source\":\"homes\",\"url\":\"https://homes.jp/1\"}]")
        #expect(existing.investmentSummary == "{\"roi\":3.5}")
        #expect(existing.extractedFeaturesJSON == "[\"南向き\",\"角部屋\"]")
        #expect(existing.imageCategoriesJSON == "{\"exterior\":[\"img1.jpg\"]}")
        #expect(existing.dedupCandidatesJSON == "[\"key2\"]")
        #expect(existing.floorPlanImagesJSON == "[\"plan1.jpg\"]")
        #expect(existing.suumoImagesJSON == "[\"suumo1.jpg\"]")
        #expect(existing.aiRecommendationSummary == "おすすめ物件")
        #expect(existing.aiRecommendationFlagsJSON == "{\"is_recommended\":true}")
        #expect(existing.aiRecommendationAction == "買い")
    }

    @Test("フル同期: enrichment 値ありの new で既存が上書きされる")
    func fullSyncOverwritesEnrichment() {
        let existing = makeListing(
            hazardInfo: "{\"flood\":\"low\"}",
            ssRadarData: "{\"score\":85}"
        )

        let fullNew = makeListing(
            hazardInfo: "{\"flood\":\"high\"}",
            ssRadarData: "{\"score\":92}"
        )

        ListingStore.shared.updateFromSupabase(existing, from: fullNew)

        #expect(existing.hazardInfo == "{\"flood\":\"high\"}")
        #expect(existing.ssRadarData == "{\"score\":92}")
    }

    @Test("軽量同期: 住まいサーフィンスカラー値は nil-coalescing で保持される")
    func lightSyncPreservesSuumaiScalars() {
        let existing = makeListing(
            ssLookupStatus: "found",
            ssProfitPct: 15
        )

        let lightNew = makeListing()

        ListingStore.shared.updateFromSupabase(existing, from: lightNew)

        #expect(existing.ssLookupStatus == "found")
        #expect(existing.ssProfitPct == 15)
    }

    @Test("軽量同期: コアフィールド (name, priceMan, address) は常に更新される")
    func lightSyncUpdatesCoreFields() {
        let existing = makeListing(name: "旧名称")
        existing.priceMan = 5000
        existing.address = "東京都渋谷区1-1"

        let lightNew = makeListing(name: "新名称")
        lightNew.priceMan = 5500
        lightNew.address = "東京都渋谷区2-2"

        ListingStore.shared.updateFromSupabase(existing, from: lightNew)

        #expect(existing.name == "新名称")
        #expect(existing.priceMan == 5500)
        #expect(existing.address == "東京都渋谷区2-2")
    }

    // MARK: - updateEnrichmentFields: enrichment レイジーロード

    @Test("updateEnrichmentFields: nil → 値ありで全フィールドが更新される")
    func enrichmentUpdateFromNil() {
        let existing = makeListing()
        let incoming = makeListing(
            hazardInfo: "{\"flood\":\"medium\"}",
            ssRadarData: "{\"score\":90}",
            reinfolibMarketData: "{\"avg\":4500}",
            priceHistoryJSON: "[{\"p\":5000}]",
            altSourcesJSON: "[{\"s\":\"homes\"}]",
            investmentSummary: "{\"roi\":4.0}",
            aiRecommendationSummary: "検討価値あり",
            commuteInfoJSON: "{\"total_min\":45}"
        )

        SupabaseListingStore.updateEnrichmentFields(existing, from: incoming)

        #expect(existing.hazardInfo == "{\"flood\":\"medium\"}")
        #expect(existing.ssRadarData == "{\"score\":90}")
        #expect(existing.reinfolibMarketData == "{\"avg\":4500}")
        #expect(existing.priceHistoryJSON == "[{\"p\":5000}]")
        #expect(existing.altSourcesJSON == "[{\"s\":\"homes\"}]")
        #expect(existing.investmentSummary == "{\"roi\":4.0}")
        #expect(existing.aiRecommendationSummary == "検討価値あり")
        #expect(existing.commuteInfoJSON == "{\"total_min\":45}")
    }

    @Test("updateEnrichmentFields: 既存値あり・incoming nil → 既存値が保持される")
    func enrichmentPreservesExistingOnNilIncoming() {
        let existing = makeListing(
            hazardInfo: "{\"flood\":\"low\"}",
            ssRadarData: "{\"score\":80}",
            aiRecommendationSummary: "良い物件"
        )
        let incoming = makeListing()

        SupabaseListingStore.updateEnrichmentFields(existing, from: incoming)

        #expect(existing.hazardInfo == "{\"flood\":\"low\"}")
        #expect(existing.ssRadarData == "{\"score\":80}")
        #expect(existing.aiRecommendationSummary == "良い物件")
    }

    @Test("updateEnrichmentFields: 既存値あり・incoming 値あり → incoming で上書き")
    func enrichmentOverwritesWithIncoming() {
        let existing = makeListing(
            hazardInfo: "{\"flood\":\"low\"}",
            commuteInfoJSON: "{\"old\":true}"
        )
        let incoming = makeListing(
            hazardInfo: "{\"flood\":\"high\"}",
            commuteInfoJSON: "{\"new\":true}"
        )

        SupabaseListingStore.updateEnrichmentFields(existing, from: incoming)

        #expect(existing.hazardInfo == "{\"flood\":\"high\"}")
        #expect(existing.commuteInfoJSON == "{\"new\":true}")
    }

    @Test("updateEnrichmentFields: commuteInfoV2JSON が nil なら既存保持")
    func enrichmentPreservesCommuteV2OnNil() {
        let existing = makeListing(commuteInfoV2JSON: "{\"v2\":true}")
        let incoming = makeListing()

        SupabaseListingStore.updateEnrichmentFields(existing, from: incoming)

        #expect(existing.commuteInfoV2JSON == "{\"v2\":true}")
    }

    // MARK: - enrichmentFetchedAt キャッシュ判定

    @Test("enrichmentFetchedAt が nil なら未取得（レイジーロード対象）")
    func enrichmentFetchedAtNilMeansNotFetched() {
        let listing = makeListing()
        #expect(listing.enrichmentFetchedAt == nil)
    }

    @Test("enrichmentFetchedAt が設定済みなら取得済み（レイジーロード不要）")
    func enrichmentFetchedAtSetMeansFetched() {
        let listing = makeListing(enrichmentFetchedAt: Date())
        #expect(listing.enrichmentFetchedAt != nil)
    }

    // MARK: - decodeDTOs: 軽量ビューレスポンス（alt_sources_json/price_history_json なし）

    @Test("decodeDTOs: alt_sources_json と price_history_json が null でもデコード成功")
    func decodeDTOsWithNullHeavyFields() throws {
        let json: [[String: Any]] = [[
            "identity_key": "suumo_test_1",
            "source": "suumo",
            "url": "https://suumo.jp/test/1",
            "name": "テストマンション",
            "property_type": "chuko",
            "is_active": true,
            "alt_sources_json": NSNull(),
            "price_history_json": NSNull(),
        ]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let dtos = try SupabaseListingStore.decodeDTOs(from: data)
        #expect(dtos.count == 1)
        #expect(dtos[0].name == "テストマンション")
    }

    @Test("decodeDTOs: alt_sources_json/price_history_json がキー自体存在しなくてもデコード成功")
    func decodeDTOsWithMissingHeavyFields() throws {
        let json: [[String: Any]] = [[
            "identity_key": "suumo_test_2",
            "source": "suumo",
            "url": "https://suumo.jp/test/2",
            "name": "テストマンション2",
            "property_type": "chuko",
            "is_active": true,
        ]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let dtos = try SupabaseListingStore.decodeDTOs(from: data)
        #expect(dtos.count == 1)
        #expect(dtos[0].name == "テストマンション2")
    }

    // MARK: - update() 通勤データ: パイプライン → 既存の優先ロジック

    @Test("update: 通勤データ nil の new → 既存通勤データ保持")
    func updatePreservesCommuteOnNilNew() {
        let existing = makeListing(commuteInfoJSON: "{\"total_min\":30}")
        let lightNew = makeListing()

        ListingStore.shared.updateFromSupabase(existing, from: lightNew)

        #expect(existing.commuteInfoJSON == "{\"total_min\":30}")
    }

    // MARK: - decodeDTOs: スキーマドリフト防御

    private func validRow(_ n: Int) -> [String: Any] {
        [
            "identity_key": "suumo_test_\(n)",
            "source": "suumo",
            "url": "https://suumo.jp/test/\(n)",
            "name": "テストマンション\(n)",
            "property_type": "chuko",
            "is_active": true,
        ]
    }

    /// name に数値を入れて型不一致で decode を失敗させる
    private func brokenRow(_ n: Int) -> [String: Any] {
        var row = validRow(n)
        row["name"] = 12345
        return row
    }

    @Test("decodeDTOs: 半数超の行が decode 失敗したら throw する（全物件サイレント消失防止）")
    func decodeDTOsThrowsOnMajorityFailure() throws {
        let json: [[String: Any]] = [brokenRow(1), brokenRow(2), validRow(3)]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) {
            _ = try SupabaseListingStore.decodeDTOs(from: data)
        }
    }

    @Test("decodeDTOs: 全行 decode 失敗でも空配列を返さず throw する")
    func decodeDTOsThrowsOnTotalFailure() throws {
        let json: [[String: Any]] = [brokenRow(1), brokenRow(2)]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) {
            _ = try SupabaseListingStore.decodeDTOs(from: data)
        }
    }

    @Test("decodeDTOs: 少数の行だけ失敗した場合は成功分を返す")
    func decodeDTOsToleratesMinorityFailure() throws {
        let json: [[String: Any]] = [validRow(1), validRow(2), brokenRow(3)]
        let data = try JSONSerialization.data(withJSONObject: json)
        let dtos = try SupabaseListingStore.decodeDTOs(from: data)
        #expect(dtos.count == 2)
    }
}
