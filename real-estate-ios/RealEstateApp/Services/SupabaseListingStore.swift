//
//  SupabaseListingStore.swift
//  RealEstateApp
//
//  Supabase REST API (listings_feed view) から物件データを取得し、
//  既存の ListingStore.syncToDatabase() と同じ方式で SwiftData に同期する。
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
    private let lastSyncKeyShinchiku = "supabase.lastSync.shinchiku"
    private let pageSize = 100

    private init() {}

    // MARK: - Public

    /// 次回の Supabase 同期を差分ではなく全件取得にする。
    func clearSyncState() {
        defaults.removeObject(forKey: lastSyncKeyChuko)
        defaults.removeObject(forKey: lastSyncKeyShinchiku)
    }

    /// Supabase から物件データを取得して SwiftData に同期する。
    /// 初回はフルフェッチ、2回目以降は差分同期。
    func refresh(modelContext: ModelContext) async throws -> (chukoNew: Int, shinchikuNew: Int) {
        async let chukoResult = fetchAndSync(propertyType: "chuko", modelContext: modelContext)
        async let shinResult = fetchAndSync(propertyType: "shinchiku", modelContext: modelContext)

        let (chuko, shin) = try await (chukoResult, shinResult)
        return (chuko, shin)
    }

    // MARK: - Private

    private func fetchAndSync(propertyType: String, modelContext: ModelContext) async throws -> Int {
        let syncKey = propertyType == "chuko" ? lastSyncKeyChuko : lastSyncKeyShinchiku
        var lastSync = defaults.string(forKey: syncKey)

        let descriptor = FetchDescriptor<Listing>(predicate: #Predicate { $0.propertyType == propertyType })
        let localCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        if localCount == 0 {
            lastSync = nil
            defaults.removeObject(forKey: syncKey)
        }

        let dtos: [ListingDTO]
        if let lastSync = lastSync {
            dtos = try await fetchIncremental(propertyType: propertyType, since: lastSync)
        } else {
            dtos = try await fetchAll(propertyType: propertyType)
        }

        if dtos.isEmpty {
            return 0
        }

        let newCount = syncToDatabase(dtos: dtos, propertyType: propertyType, modelContext: modelContext, isIncremental: lastSync != nil)

        // 同期タイムスタンプを更新 (ISO 8601)
        let now = ISO8601DateFormatter().string(from: Date())
        defaults.set(now, forKey: syncKey)

        return newCount
    }

    /// 全件取得 (ページネーション)
    private func fetchAll(propertyType: String) async throws -> [ListingDTO] {
        var allDTOs: [ListingDTO] = []
        var offset = 0

        while true {
            let range = offset...(offset + pageSize - 1)
            let (data, response) = try await client.select(
                from: "listings_feed",
                columns: "*",
                filters: [
                    ("is_active", "eq.true"),
                    ("property_type", "eq.\(propertyType)")
                ],
                order: "updated_at.desc",
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

    /// 差分取得 (since timestamp)
    private func fetchIncremental(propertyType: String, since: String) async throws -> [ListingDTO] {
        let params: [String: Any] = ["since_ts": since]
        let data = try await client.rpc("get_listings_since", params: params)

        var dtos = try Self.decodeDTOs(from: data)
        dtos = dtos.filter { $0.property_type == propertyType }

        logger.info("Supabase incremental(\(propertyType, privacy: .public)) since \(since, privacy: .public): \(dtos.count) 件")
        return dtos
    }

    /// SwiftData に同期 (既存 ListingStore.syncToDatabase のロジックを流用)
    private func syncToDatabase(dtos: [ListingDTO], propertyType: String, modelContext: ModelContext, isIncremental: Bool) -> Int {
        let fetchedAt = Date()

        do {
            let predicate = #Predicate<Listing> { $0.propertyType == propertyType }
            let descriptor = FetchDescriptor<Listing>(predicate: predicate)
            let existing = try modelContext.fetch(descriptor)
            let existingByKey = Dictionary(existing.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })

            for e in existing {
                e.isNew = false
                e.isNewBuilding = false
            }

            var newCount = 0
            var incomingKeys = Set<String>()

            let hasAnnotationBackup = UserAnnotationStore.hasBackup

            for dto in dtos {
                guard let listing = Listing.from(dto: dto, fetchedAt: fetchedAt) else { continue }
                listing.propertyType = propertyType
                let key = listing.identityKey
                incomingKeys.insert(key)

                if let same = existingByKey[key] {
                    if same.isDelisted { same.isDelisted = false }
                    ListingStore.shared.updateFromSupabase(same, from: listing)
                } else {
                    if listing.isNew { newCount += 1 }
                    if let seen = listing.firstSeenAt,
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

            if hasAnnotationBackup && propertyType == "shinchiku" {
                UserAnnotationStore.clearBackup()
            }

            try modelContext.save()
            return newCount
        } catch {
            logger.error("Supabase syncToDatabase 失敗 (\(propertyType, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return 0
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

        let processedData = try JSONSerialization.data(withJSONObject: jsonArray)
        return try JSONDecoder().decode([ListingDTO].self, from: processedData)
    }

    // MARK: - Constants

    private static let jsonbStringFields = [
        "hazard_info", "commute_info", "commute_info_v2",
        "reinfolib_market_data", "mansion_review_data", "estat_population_data",
        "ss_radar_data", "ss_past_market_trends", "ss_surrounding_properties", "ss_price_judgments",
    ]

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
