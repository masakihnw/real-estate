//
//  TransactionStore.swift
//  RealEstateApp
//
//  transactions.json の取得・SwiftData 同期を担う。
//  ListingStore と同様の ETag ベース差分チェックを採用。
//

import Foundation
import SwiftData

@Observable
final class TransactionStore {
    static let shared = TransactionStore()

    // MARK: - デフォルト URL（GitHub raw）

    static let defaultURL = "https://raw.githubusercontent.com/masakihnw/real-estate/main/scraping-tool/results/transactions.json"

    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastFetchedAt: Date?
    private(set) var lastRefreshHadChanges = true

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120  // transactions.json は大きい可能性
        return URLSession(configuration: config)
    }()

    private let defaults = UserDefaults.standard
    private let urlKey = "realestate.transactionsURL"
    private let lastFetchedKey = "realestate.transactions.lastFetchedAt"
    private let etagKey = "realestate.etag.transactions"

    /// JSON URL（空ならデフォルトを使う）
    var transactionsURL: String {
        get { defaults.string(forKey: urlKey) ?? "" }
        set { defaults.set(newValue, forKey: urlKey) }
    }

    /// 実際に使用する URL
    var effectiveURL: String {
        let custom = transactionsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? Self.defaultURL : custom
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

        // SwiftData が空なら ETag クリアしてフルフェッチ
        let descriptor = FetchDescriptor<TransactionRecord>()
        let existingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        if existingCount == 0 {
            defaults.removeObject(forKey: etagKey)
        }

        do {
            let result = try await fetchData()
            if let (data, newETag) = result {
                let count = try syncToDatabase(data: data, modelContext: modelContext)
                if let etag = newETag {
                    defaults.set(etag, forKey: etagKey)
                }
                lastRefreshHadChanges = true
                print("[TransactionStore] 同期完了: \(count) 件")
            } else {
                // 304 Not Modified
                print("[TransactionStore] 変更なし (304)")
            }
        } catch {
            lastError = error.localizedDescription
            print("[TransactionStore] エラー: \(error)")
        }

        lastFetchedAt = Date()
        defaults.set(lastFetchedAt, forKey: lastFetchedKey)
        isRefreshing = false
    }

    // MARK: - Fetch

    private func fetchData() async throws -> (Data, String?)? {
        guard let url = URL(string: effectiveURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // ETag による差分判定
        if let etag = defaults.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await Self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch httpResponse.statusCode {
        case 200:
            let etag = httpResponse.value(forHTTPHeaderField: "ETag")
            return (data, etag)
        case 304:
            return nil  // 変更なし
        default:
            throw URLError(.init(rawValue: httpResponse.statusCode))
        }
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
    }
}
