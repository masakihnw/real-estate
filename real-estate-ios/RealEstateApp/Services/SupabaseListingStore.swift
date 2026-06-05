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
    private let syncVersionKey = "supabase.syncVersion"
    private let pageSize = 100

    static let currentSyncVersion = 4

    private init() {
        migrateSyncVersionIfNeeded()
    }

    /// syncVersion が古い場合、同期状態をリセットしてフル再同期を強制する。
    func migrateSyncVersionIfNeeded() {
        let stored = defaults.integer(forKey: syncVersionKey)
        if stored < Self.currentSyncVersion {
            clearSyncState()
            defaults.set(Self.currentSyncVersion, forKey: syncVersionKey)
        }
    }

    // MARK: - Public

    /// 次回の Supabase 同期を差分ではなく全件取得にする。
    func clearSyncState() {
        defaults.removeObject(forKey: lastSyncKeyChuko)
    }

    /// Supabase から中古物件データを取得して SwiftData に同期する。
    /// 初回はフルフェッチ、2回目以降は差分同期。
    func refresh(modelContext: ModelContext) async throws -> (chukoNew: Int, shinchikuNew: Int) {
        purgeNonChukoListings(modelContext: modelContext)

        let likedKeys = await MainActor.run { BuildingPreferenceStore.shared.likedKeys }

        let chukoFetch = try await fetchDTOs(propertyType: "chuko", modelContext: modelContext)

        let chukoNew = chukoFetch.dtos.isEmpty ? 0 :
            syncToDatabase(dtos: chukoFetch.dtos, propertyType: "chuko", modelContext: modelContext, isIncremental: chukoFetch.isIncremental, likedKeys: likedKeys)

        if !chukoFetch.delistedKeys.isEmpty {
            applyDelistings(keys: chukoFetch.delistedKeys, propertyType: "chuko", modelContext: modelContext)
        }

        if !chukoFetch.dtos.isEmpty || !chukoFetch.delistedKeys.isEmpty {
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
        let delistedKeys: [String]
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
        var delistedKeys: [String] = []
        if let lastSync = lastSync {
            async let incrementalTask = fetchIncremental(propertyType: propertyType, since: lastSync)
            async let delistTask = fetchDelistedKeys(since: lastSync)
            dtos = try await incrementalTask
            do {
                delistedKeys = try await delistTask
            } catch {
                logger.warning("fetchDelistedKeys 失敗（スキップ）: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            dtos = try await fetchAll(propertyType: propertyType)
            let likedInactive = try await fetchLikedInactiveListings()
                .filter { $0.property_type == propertyType }
            dtos.append(contentsOf: likedInactive)
        }

        return FetchResult(dtos: dtos, isIncremental: lastSync != nil, delistedKeys: delistedKeys)
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

    /// 差分同期中に掲載終了した物件の identity_key を取得する。
    /// listings テーブルを直接クエリするため、ビューから消えた物件も検知できる。
    private func fetchDelistedKeys(since: String) async throws -> [String] {
        let params: [String: Any] = ["since_ts": since]
        let data = try await client.rpc("get_delisted_since", params: params)
        let rows = try JSONDecoder().decode([[String: String]].self, from: data)
        let keys = rows.compactMap { $0["identity_key"] }
        logger.info("Supabase delisted since \(since, privacy: .public): \(keys.count) 件")
        return keys
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

    /// 差分同期で掲載終了が判明した物件をローカル DB に反映する。
    func applyDelistings(keys: [String], propertyType: String, modelContext: ModelContext) {
        guard !keys.isEmpty else { return }
        let delistedSet = Set(keys)

        do {
            let predicate = #Predicate<Listing> { $0.propertyType == propertyType && !$0.isDelisted }
            let descriptor = FetchDescriptor<Listing>(predicate: predicate)
            let existing = try modelContext.fetch(descriptor)

            var delistedCount = 0
            var deletedCount = 0
            for listing in existing {
                let matchByDbKey = listing.supabaseIdentityKey.map { delistedSet.contains($0) } ?? false
                guard matchByDbKey else { continue }

                let hasUserData = listing.isLiked || listing.hasComments || listing.hasPhotos || !(listing.memo ?? "").isEmpty
                if hasUserData {
                    listing.isDelisted = true
                    delistedCount += 1
                } else {
                    modelContext.delete(listing)
                    deletedCount += 1
                }
            }

            if delistedCount + deletedCount > 0 {
                try modelContext.save()
                logger.info("applyDelistings: \(delistedCount) marked delisted, \(deletedCount) deleted")
            }
        } catch {
            logger.error("applyDelistings 失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 新築廃止以前にローカルに同期された非chuko物件を一括削除する。
    private func purgeNonChukoListings(modelContext: ModelContext) {
        do {
            let predicate = #Predicate<Listing> { $0.propertyType != "chuko" }
            let descriptor = FetchDescriptor<Listing>(predicate: predicate)
            let stale = try modelContext.fetch(descriptor)
            guard !stale.isEmpty else { return }
            for listing in stale {
                modelContext.delete(listing)
            }
            try modelContext.save()
            logger.info("purgeNonChukoListings: \(stale.count) 件削除")
        } catch {
            logger.error("purgeNonChukoListings 失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// SwiftData に同期 (既存 ListingStore.syncToDatabase のロジックを流用)
    private func syncToDatabase(dtos: [ListingDTO], propertyType: String, modelContext: ModelContext, isIncremental: Bool, likedKeys: Set<String> = []) -> Int {
        if !isIncremental && !UserAnnotationStore.hasBackup {
            UserAnnotationStore.backup(from: modelContext)
        }

        let fetchedAt = Date()

        do {
            let predicate = #Predicate<Listing> { $0.propertyType == propertyType }
            let descriptor = FetchDescriptor<Listing>(predicate: predicate)
            let existing = try modelContext.fetch(descriptor)

            // マッチング辞書: Supabase identity_key（優先）+ Swift computed identityKey（フォールバック）
            var existingByDbKey: [String: Listing] = [:]
            var existingBySwiftKey: [String: Listing] = [:]
            for e in existing {
                if let dbKey = e.supabaseIdentityKey, existingByDbKey[dbKey] == nil {
                    existingByDbKey[dbKey] = e
                }
                if existingBySwiftKey[e.identityKey] == nil {
                    existingBySwiftKey[e.identityKey] = e
                }
            }

            for e in existing {
                e.isNew = false
                e.isNewBuilding = false
                e.isRelisted = false
            }

            var newCount = 0
            var incomingSwiftKeys = Set<String>()
            var matchedExisting = Set<ObjectIdentifier>()

            let hasAnnotationBackup = UserAnnotationStore.hasBackup

            for dto in dtos {
                guard let listing = Listing.from(dto: dto, fetchedAt: fetchedAt) else { continue }
                listing.propertyType = propertyType
                let swiftKey = listing.identityKey
                let dbKey = dto.identity_key

                // Supabase identity_key → Swift computed identityKey の順でマッチ
                let matched: Listing? = dbKey.flatMap { existingByDbKey[$0] }
                    ?? existingBySwiftKey[swiftKey]

                if dto.is_active == false {
                    if let existing = matched {
                        matchedExisting.insert(ObjectIdentifier(existing))
                        let hasUserData = existing.isLiked || existing.hasComments || existing.hasPhotos || !(existing.memo ?? "").isEmpty
                        if hasUserData {
                            existing.isDelisted = true
                            existing.supabaseIdentityKey = dbKey ?? existing.supabaseIdentityKey
                        } else {
                            modelContext.delete(existing)
                        }
                    } else if likedKeys.contains(swiftKey) {
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

                incomingSwiftKeys.insert(swiftKey)

                if let same = matched {
                    matchedExisting.insert(ObjectIdentifier(same))
                    if same.isDelisted {
                        same.isDelisted = false
                        same.isRelisted = true
                        same.addedAt = fetchedAt
                    }
                    same.supabaseIdentityKey = dbKey ?? same.supabaseIdentityKey
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
            if !isIncremental && !incomingSwiftKeys.isEmpty && incomingSwiftKeys.count >= existing.count / 10 {
                for e in existing {
                    if matchedExisting.contains(ObjectIdentifier(e)) { continue }
                    let hasUserData = e.isLiked || e.hasComments || e.hasPhotos || !(e.memo ?? "").isEmpty
                    if hasUserData {
                        if !e.isDelisted { e.isDelisted = true }
                    } else {
                        modelContext.delete(e)
                    }
                }
            }

            // 重複レコードのクリーンアップ（フルフェッチ時のみ）
            // save() 前のフェッチなので、上記ループで insert した未コミットレコードも含まれる
            if !isIncremental {
                let allAfterSync = try modelContext.fetch(descriptor)
                var seenDbKeys: [String: Listing] = [:]
                for listing in allAfterSync {
                    guard let dbKey = listing.supabaseIdentityKey else { continue }
                    if let existing = seenDbKeys[dbKey] {
                        let (keep, remove) = Self.pickKeepAndRemove(existing, listing)
                        modelContext.delete(remove)
                        seenDbKeys[dbKey] = keep
                    } else {
                        seenDbKeys[dbKey] = listing
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

    static func pickKeepAndRemove(_ a: Listing, _ b: Listing) -> (keep: Listing, remove: Listing) {
        let aHasData = a.isLiked || a.hasComments || a.hasPhotos || !(a.memo ?? "").isEmpty
        let bHasData = b.isLiked || b.hasComments || b.hasPhotos || !(b.memo ?? "").isEmpty
        if aHasData && !bHasData { return (a, b) }
        if bHasData && !aHasData { return (b, a) }
        if aHasData && bHasData {
            logger.warning("pickKeepAndRemove: 両レコードにユーザーデータあり。削除側のデータは失われる (a=\(a.url, privacy: .public) b=\(b.url, privacy: .public))")
        }
        return a.fetchedAt >= b.fetchedAt ? (a, b) : (b, a)
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
        if new.hasFloorPlanImagesServer || existing.hasFloorPlanImages { existing.hasFloorPlanImagesServer = true }
        if new.hasPropertyImagesServer || existing.hasSuumoImages { existing.hasPropertyImagesServer = true }
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
        "ai_scoring_reasoning",
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
