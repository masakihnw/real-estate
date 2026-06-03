//
//  SupabaseListingStore.swift
//  RealEstateApp
//
//  Supabase REST API から物件データを取得し SwiftData に同期する。
//
//  2層データ取得:
//    - リスト/マップ同期: listings_feed_light (コアフィールドのみ、高速)
//    - 詳細画面: get_listing_detail RPC (全 enrichment、レイジーロード)
//
//  差分同期: lastSyncTimestamp 以降に updated_at が変わった物件のみ取得。
//  初回: 全件取得 (100件/ページのページネーション)。
//

import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.realestate", category: "SupabaseListingStore")

@Observable
final class SupabaseListingStore {
    static let shared = SupabaseListingStore()

    private let client = SupabaseClient.shared
    private let defaults = UserDefaults.standard

    private let lastSyncKeyChuko = "supabase.lastSync.chuko"
    private let pageSize = 100

    private init() {}

    // MARK: - Public

    /// 次回の Supabase 同期を差分ではなく全件取得にする。
    func clearSyncState() {
        defaults.removeObject(forKey: lastSyncKeyChuko)
    }

    /// Supabase から中古物件データを取得して SwiftData に同期する。
    /// 初回はフルフェッチ、2回目以降は差分同期。
    func refresh(modelContext: ModelContext) async throws -> (chukoNew: Int, shinchikuNew: Int) {
        let likedKeys = await MainActor.run { BuildingPreferenceStore.shared.likedKeys }

        let chukoFetch = try await fetchDTOs(propertyType: "chuko", modelContext: modelContext)

        let chukoNew = chukoFetch.dtos.isEmpty ? 0 :
            syncToDatabase(dtos: chukoFetch.dtos, propertyType: "chuko", modelContext: modelContext, isIncremental: chukoFetch.isIncremental, likedKeys: likedKeys)
        if !chukoFetch.dtos.isEmpty {
            defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: lastSyncKeyChuko)
        }

        if UserAnnotationStore.hasBackup {
            UserAnnotationStore.clearBackup()
        }

        return (chukoNew, 0)
    }

    // MARK: - Private

    private struct FetchResult {
        let dtos: [ListingDTO]
        let isIncremental: Bool
    }

    /// ネットワーク取得 + デコードのみ（ModelContext の読み取りは最小限に抑え、書き込みは行わない）
    private func fetchDTOs(propertyType: String, modelContext: ModelContext) async throws -> FetchResult {
        let syncKey = lastSyncKeyChuko
        var lastSync = defaults.string(forKey: syncKey)

        let descriptor = FetchDescriptor<Listing>(predicate: #Predicate { $0.propertyType == propertyType })
        let localCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        if localCount == 0 {
            lastSync = nil
            defaults.removeObject(forKey: syncKey)
        }

        var dtos: [ListingDTO]
        if let lastSync = lastSync {
            dtos = try await fetchIncremental(propertyType: propertyType, since: lastSync)
        } else {
            dtos = try await fetchAll(propertyType: propertyType)
            let likedInactive = try await fetchLikedInactiveListings()
                .filter { $0.property_type == propertyType }
            dtos.append(contentsOf: likedInactive)
        }

        return FetchResult(dtos: dtos, isIncremental: lastSync != nil)
    }

    /// 全件取得 (ページネーション) — 軽量ビューを使用
    private func fetchAll(propertyType: String) async throws -> [ListingDTO] {
        var allDTOs: [ListingDTO] = []
        var offset = 0

        while true {
            let range = offset...(offset + pageSize - 1)
            let (data, response) = try await client.select(
                from: "listings_feed_light",
                columns: "*",
                filters: [
                    ("is_active", "eq.true"),
                    ("property_type", "eq.\(propertyType)")
                ],
                order: "created_at.desc",
                range: range
            )

            let dtos = try Self.decodeDTOs(from: data)
            allDTOs.append(contentsOf: dtos)

            if let total = SupabaseClient.parseTotalCount(from: response) {
                if allDTOs.count >= total { break }
            } else if dtos.count < pageSize {
                break
            }

            offset += pageSize
        }

        logger.info("Supabase fetchAll(\(propertyType, privacy: .public)): \(allDTOs.count) 件取得")
        return allDTOs
    }

    /// Like済み非アクティブ物件を取得
    private func fetchLikedInactiveListings() async throws -> [ListingDTO] {
        let data = try await client.rpc("get_liked_inactive_listings")
        let dtos = try Self.decodeDTOs(from: data)
        logger.info("Supabase liked inactive: \(dtos.count) 件取得")
        return dtos
    }

    /// 差分取得 (since timestamp) — 軽量ビューを使用
    private func fetchIncremental(propertyType: String, since: String) async throws -> [ListingDTO] {
        let params: [String: Any] = ["since_ts": since]
        let data = try await client.rpc("get_listings_since_light", params: params)

        var dtos = try Self.decodeDTOs(from: data)
        dtos = dtos.filter { $0.property_type == propertyType }

        logger.info("Supabase incremental(\(propertyType, privacy: .public)) since \(since, privacy: .public): \(dtos.count) 件")
        return dtos
    }

    /// SwiftData に同期 (既存 ListingStore.syncToDatabase のロジックを流用)
    private func syncToDatabase(dtos: [ListingDTO], propertyType: String, modelContext: ModelContext, isIncremental: Bool, likedKeys: Set<String> = []) -> Int {
        // フルフェッチ時: identityKey 変更による不一致に備え自動バックアップ
        if !isIncremental && !UserAnnotationStore.hasBackup {
            UserAnnotationStore.backup(from: modelContext)
        }

        let fetchedAt = Date()

        do {
            let predicate = #Predicate<Listing> { $0.propertyType == propertyType }
            let descriptor = FetchDescriptor<Listing>(predicate: predicate)
            let existing = try modelContext.fetch(descriptor)
            let existingByKey = Dictionary(existing.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })

            for e in existing {
                e.isNew = false
                e.isNewBuilding = false
                e.isRelisted = false
            }

            var newCount = 0
            var incomingKeys = Set<String>()

            let hasAnnotationBackup = UserAnnotationStore.hasBackup

            for dto in dtos {
                guard let listing = Listing.from(dto: dto, fetchedAt: fetchedAt) else { continue }
                listing.propertyType = propertyType
                let key = listing.identityKey

                // 非アクティブ物件: Supabase で is_active=false になった
                if dto.is_active == false {
                    if let existing = existingByKey[key] {
                        let hasUserData = existing.isLiked || existing.hasComments || existing.hasPhotos || !(existing.memo ?? "").isEmpty
                        if hasUserData {
                            existing.isDelisted = true
                        } else {
                            modelContext.delete(existing)
                        }
                    } else if likedKeys.contains(key) {
                        listing.isLiked = true
                        listing.isDelisted = true
                        if let createdAt = dto.created_at,
                           let parsed = Self.parseSupabaseTimestamp(createdAt) {
                            listing.addedAt = parsed
                        } else if let seen = listing.firstSeenAt,
                                  let parsed = Self.isoDateFormatter.date(from: seen) {
                            listing.addedAt = parsed
                        } else {
                            listing.addedAt = fetchedAt
                        }
                        if hasAnnotationBackup {
                            UserAnnotationStore.restore(to: listing)
                        }
                        modelContext.insert(listing)
                    }
                    continue
                }

                incomingKeys.insert(key)

                if let same = existingByKey[key] {
                    if same.isDelisted {
                        same.isDelisted = false
                        same.isRelisted = true
                        same.addedAt = fetchedAt
                    }
                    ListingStore.shared.updateFromSupabase(same, from: listing)
                } else {
                    if listing.isNew { newCount += 1 }
                    if let createdAt = dto.created_at,
                       let parsed = Self.parseSupabaseTimestamp(createdAt) {
                        listing.addedAt = parsed
                    } else if let seen = listing.firstSeenAt,
                              let parsed = Self.isoDateFormatter.date(from: seen) {
                        listing.addedAt = parsed
                    } else {
                        listing.addedAt = fetchedAt
                    }
                    if hasAnnotationBackup {
                        UserAnnotationStore.restore(to: listing)
                    }
                    modelContext.insert(listing)
                }
            }

            // フルフェッチ時のみ、Supabase から消えた物件を処理
            // 安全策: 取得件数が0または既存の10%未満の場合はスキップ（API障害時の誤削除防止）
            if !isIncremental && !incomingKeys.isEmpty && incomingKeys.count >= existing.count / 10 {
                for e in existing where !incomingKeys.contains(e.identityKey) {
                    let hasUserData = e.isLiked || e.hasComments || e.hasPhotos || !(e.memo ?? "").isEmpty
                    if hasUserData {
                        if !e.isDelisted { e.isDelisted = true }
                    } else {
                        modelContext.delete(e)
                    }
                }
            }

            try modelContext.save()
            return newCount
        } catch {
            logger.error("Supabase syncToDatabase 失敗 (\(propertyType, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    // MARK: - Detail Lazy Loading

    /// 個別物件の全 enrichment データを取得し SwiftData に反映する。
    /// 詳細画面を開いた際にレイジーロードで呼ばれる。
    func fetchDetail(identityKey: String, modelContext: ModelContext) async throws {
        let params: [String: Any] = ["p_identity_key": identityKey]
        let data = try await client.rpc("get_listing_detail", params: params)
        let dtos = try Self.decodeDTOs(from: data)

        guard let dto = dtos.first,
              let incoming = Listing.from(dto: dto, fetchedAt: Date()) else {
            logger.warning("get_listing_detail: \(identityKey, privacy: .public) のデータなし")
            return
        }

        let predicate = #Predicate<Listing> { $0.identityKey == identityKey }
        let descriptor = FetchDescriptor<Listing>(predicate: predicate)
        guard let existing = try modelContext.fetch(descriptor).first else {
            logger.warning("fetchDetail: ローカルに \(identityKey, privacy: .public) が存在しない")
            return
        }

        Self.updateEnrichmentFields(existing, from: incoming)
        existing.enrichmentFetchedAt = Date()
        try modelContext.save()

        logger.info("fetchDetail: \(identityKey, privacy: .public) の enrichment を取得・保存")
    }

    /// enrichment JSONB フィールドのみを更新する（軽量同期で nil だったフィールドを埋める）
    static func updateEnrichmentFields(_ existing: Listing, from new: Listing) {
        existing.floorPlanImagesJSON = new.floorPlanImagesJSON ?? existing.floorPlanImagesJSON
        existing.suumoImagesJSON = new.suumoImagesJSON ?? existing.suumoImagesJSON
        existing.hazardInfo = new.hazardInfo ?? existing.hazardInfo
        existing.ssRadarData = new.ssRadarData ?? existing.ssRadarData
        existing.ssPastMarketTrends = new.ssPastMarketTrends ?? existing.ssPastMarketTrends
        existing.ssSurroundingProperties = new.ssSurroundingProperties ?? existing.ssSurroundingProperties
        existing.ssPriceJudgments = new.ssPriceJudgments ?? existing.ssPriceJudgments
        existing.reinfolibMarketData = new.reinfolibMarketData ?? existing.reinfolibMarketData
        existing.mansionReviewData = new.mansionReviewData ?? existing.mansionReviewData
        existing.estatPopulationData = new.estatPopulationData ?? existing.estatPopulationData
        existing.investmentSummary = new.investmentSummary ?? existing.investmentSummary
        existing.extractedFeaturesJSON = new.extractedFeaturesJSON ?? existing.extractedFeaturesJSON
        existing.imageCategoriesJSON = new.imageCategoriesJSON ?? existing.imageCategoriesJSON
        existing.dedupCandidatesJSON = new.dedupCandidatesJSON ?? existing.dedupCandidatesJSON
        existing.altSourcesJSON = new.altSourcesJSON ?? existing.altSourcesJSON
        existing.priceHistoryJSON = new.priceHistoryJSON ?? existing.priceHistoryJSON
        existing.aiRecommendationSummary = new.aiRecommendationSummary ?? existing.aiRecommendationSummary
        existing.aiRecommendationFlagsJSON = new.aiRecommendationFlagsJSON ?? existing.aiRecommendationFlagsJSON
        existing.aiRecommendationAction = new.aiRecommendationAction ?? existing.aiRecommendationAction
        if let pipelineCommute = new.commuteInfoJSON {
            existing.commuteInfoJSON = pipelineCommute
        }
        if let pipelineCommuteV2 = new.commuteInfoV2JSON {
            existing.commuteInfoV2JSON = pipelineCommuteV2
        }
    }

    // MARK: - JSON Decoding

    /// Supabase REST レスポンスを ListingDTO に変換する。
    /// JSONB カラム (objects) を文字列に変換し、alt_sources_json を alt_sources/alt_urls に分解。
    static func decodeDTOs(from data: Data) throws -> [ListingDTO] {
        guard var jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SupabaseError.decodingError("レスポンスが JSON 配列ではありません")
        }

        for i in 0..<jsonArray.count {
            var row = jsonArray[i]

            // JSONB フィールド → 文字列に変換 (既存 ListingDTO が String? で受ける)
            for key in Self.jsonbStringFields {
                if let val = row[key], !(val is NSNull), !(val is String) {
                    if let jsonData = try? JSONSerialization.data(withJSONObject: val),
                       let str = String(data: jsonData, encoding: .utf8) {
                        row[key] = str
                    }
                }
            }

            // alt_sources_json → alt_sources / alt_urls に分解
            if let altJSON = row["alt_sources_json"] as? [[String: String]] {
                row["alt_sources"] = altJSON.compactMap { $0["source"] }
                row["alt_urls"] = altJSON.compactMap { $0["url"] }
            }
            row.removeValue(forKey: "alt_sources_json")

            // price_history_json → price_history に変換
            if let histJSON = row["price_history_json"] {
                if !(histJSON is NSNull) {
                    row["price_history"] = histJSON
                }
            }
            row.removeValue(forKey: "price_history_json")

            // Supabase の id (bigint) は ListingDTO にないので除去
            row.removeValue(forKey: "id")

            jsonArray[i] = row
        }

        let decoder = JSONDecoder()
        var dtos: [ListingDTO] = []
        for (i, row) in jsonArray.enumerated() {
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                let dto = try decoder.decode(ListingDTO.self, from: rowData)
                dtos.append(dto)
            } catch {
                if dtos.isEmpty && i < 3 {
                    let name = (row["name"] as? String) ?? "unknown"
                    logger.error("DTO decode失敗 row[\(i)] \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        if dtos.isEmpty && !jsonArray.isEmpty {
            let sampleRow = try JSONSerialization.data(withJSONObject: jsonArray[0])
            return [try decoder.decode(ListingDTO.self, from: sampleRow)]
        }
        return dtos
    }

    // MARK: - Constants

    private static let jsonbStringFields = [
        "hazard_info", "commute_info", "commute_info_v2",
        "reinfolib_market_data", "mansion_review_data", "estat_population_data",
        "ss_radar_data", "ss_past_market_trends", "ss_surrounding_properties", "ss_price_judgments",
        "extracted_features", "image_categories", "dedup_candidates",
    ]

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let supabaseTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseSupabaseTimestamp(_ str: String) -> Date? {
        supabaseTimestampFormatter.date(from: str)
            ?? ISO8601DateFormatter().date(from: str)
    }
}
