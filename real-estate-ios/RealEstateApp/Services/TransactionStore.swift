//
//  TransactionStore.swift
//  RealEstateApp
//
//  transactions.json の取得・SwiftData 同期を担う。
//  ListingStore と同様の ETag ベース差分チェックを採用。
//

import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.realestate", category: "TransactionStore")

@Observable
final class TransactionStore {
    static let shared = TransactionStore()

    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastFetchedAt: Date?
    private(set) var lastRefreshHadChanges = true

    private let defaults = UserDefaults.standard
    private let lastFetchedKey = "realestate.transactions.lastFetchedAt"

    /// ListingStore と同じ useSupabase フラグを参照
    private var useSupabase: Bool {
        defaults.object(forKey: "realestate.useSupabase") as? Bool ?? true
    }

    init() {
        if let ts = defaults.object(forKey: lastFetchedKey) as? Date {
            lastFetchedAt = ts
        }
    }

    // MARK: - Public API

    @MainActor
    func refresh(modelContext: ModelContext) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        lastRefreshHadChanges = false

        do {
            let data = try await fetchFromSupabase()
            let count = try syncToDatabase(data: data, modelContext: modelContext)
            lastRefreshHadChanges = true
            logger.info("同期完了: \(count) 件")
        } catch {
            lastError = error.localizedDescription
            logger.error("エラー: \(error.localizedDescription, privacy: .public)")
        }

        lastFetchedAt = Date()
        defaults.set(lastFetchedAt, forKey: lastFetchedKey)
        isRefreshing = false
    }

    // MARK: - Supabase Fetch

    private func fetchFromSupabase() async throws -> Data {
        try await SupabaseClient.shared.rpc("get_transaction_feed")
    }

    // MARK: - Sync

    private func syncToDatabase(data: Data, modelContext: ModelContext) throws -> Int {
        let decoder = JSONDecoder()
        let feed = try decoder.decode(TransactionFeedDTO.self, from: data)

        // 既存レコードの txId → TransactionRecord マップを構築
        let descriptor = FetchDescriptor<TransactionRecord>()
        let existingRecords = try modelContext.fetch(descriptor)
        var existingMap: [String: TransactionRecord] = [:]
        for rec in existingRecords {
            existingMap[rec.txId] = rec
        }

        var newIds = Set<String>()
        var insertCount = 0
        var updateCount = 0

        for dto in feed.transactions {
            guard let record = TransactionRecord.from(dto: dto) else { continue }
            newIds.insert(record.txId)

            if let existing = existingMap[record.txId] {
                // 既存レコードを更新
                updateExisting(existing, from: record)
                updateCount += 1
            } else {
                // 新規挿入
                modelContext.insert(record)
                insertCount += 1
            }
        }

        // JSON から消えたレコードを削除
        var deleteCount = 0
        for (txId, record) in existingMap where !newIds.contains(txId) {
            modelContext.delete(record)
            deleteCount += 1
        }

        try modelContext.save()
        print("[TransactionStore] insert=\(insertCount) update=\(updateCount) delete=\(deleteCount)")
        return insertCount + updateCount
    }

    private func updateExisting(_ existing: TransactionRecord, from new: TransactionRecord) {
        existing.prefecture = new.prefecture
        existing.ward = new.ward
        existing.district = new.district
        existing.districtCode = new.districtCode
        existing.priceMan = new.priceMan
        existing.areaM2 = new.areaM2
        existing.m2Price = new.m2Price
        existing.layout = new.layout
        existing.builtYear = new.builtYear
        existing.structure = new.structure
        existing.tradePeriod = new.tradePeriod
        existing.nearestStation = new.nearestStation
        existing.estimatedWalkMin = new.estimatedWalkMin
        existing.latitude = new.latitude
        existing.longitude = new.longitude
        existing.buildingGroupId = new.buildingGroupId
        existing.estimatedBuildingName = new.estimatedBuildingName
    }
}
