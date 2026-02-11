//
//  ListingStore.swift
//  RealEstateApp
//
//  物件一覧の取得・永続化・差分検出（新規→プッシュ用）
//  中古 (latest.json) と新築 (latest_shinchiku.json) の2ソースをサポート。
//

import Foundation
import SwiftData
import UserNotifications

@Observable
final class ListingStore {
    static let shared = ListingStore()

    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastFetchedAt: Date?

    private let defaults = UserDefaults.standard
    private let chukoURLKey = "realestate.listURL"
    private let shinchikuURLKey = "realestate.shinchikuListURL"
    private let lastFetchedKey = "realestate.lastFetchedAt"

    /// 中古マンション JSON URL
    var listURL: String {
        get { defaults.string(forKey: chukoURLKey) ?? "" }
        set { defaults.set(newValue, forKey: chukoURLKey) }
    }

    /// 新築マンション JSON URL
    var shinchikuListURL: String {
        get { defaults.string(forKey: shinchikuURLKey) ?? "" }
        set { defaults.set(newValue, forKey: shinchikuURLKey) }
    }

    private init() {
        lastFetchedAt = defaults.object(forKey: lastFetchedKey) as? Date
    }

    /// 中古・新築の両方を取得し、SwiftData に反映。新規があればローカル通知を発火。
    func refresh(modelContext: ModelContext) async {
        await MainActor.run { isRefreshing = true }
        lastError = nil

        var totalNew = 0

        // 中古
        let chukoURL = listURL.trimmingCharacters(in: .whitespaces)
        if !chukoURL.isEmpty {
            let result = await fetchAndSync(urlString: chukoURL, propertyType: "chuko", modelContext: modelContext)
            totalNew += result.newCount
            if let err = result.error { lastError = err }
        }

        // 新築
        let shinURL = shinchikuListURL.trimmingCharacters(in: .whitespaces)
        if !shinURL.isEmpty {
            let result = await fetchAndSync(urlString: shinURL, propertyType: "shinchiku", modelContext: modelContext)
            totalNew += result.newCount
            if let err = result.error {
                lastError = (lastError != nil) ? "\(lastError!); \(err)" : err
            }
        }

        if chukoURL.isEmpty && shinURL.isEmpty {
            lastError = "一覧URLを設定してください"
        }

        let fetchedAt = Date()
        await MainActor.run {
            lastFetchedAt = fetchedAt
            defaults.set(fetchedAt, forKey: lastFetchedKey)
            isRefreshing = false
        }

        if totalNew > 0 {
            await notifyNewListings(count: totalNew)
        }

        // Firestore からアノテーション（いいね・メモ）を取得してマージ
        await FirebaseSyncService.shared.pullAnnotations(modelContext: modelContext)
    }

    // MARK: - Private

    private struct SyncResult {
        var newCount: Int = 0
        var error: String?
    }

    private func fetchAndSync(urlString: String, propertyType: String, modelContext: ModelContext) async -> SyncResult {
        guard let url = URL(string: urlString) else {
            return SyncResult(error: "\(propertyType) URL が不正です")
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let dtos = try JSONDecoder().decode([ListingDTO].self, from: data)
            let fetchedAt = Date()

            // 同じ propertyType の既存レコードを取得
            let descriptor = FetchDescriptor<Listing>()
            let allExisting = try modelContext.fetch(descriptor)
            let existing = allExisting.filter { $0.propertyType == propertyType }
            let existingKeys = Set(existing.map(\.identityKey))

            var newCount = 0
            var incomingKeys = Set<String>()

            for dto in dtos {
                guard var listing = Listing.from(dto: dto, fetchedAt: fetchedAt) else { continue }
                listing.propertyType = propertyType
                let key = listing.identityKey
                incomingKeys.insert(key)

                if !existingKeys.contains(key) {
                    newCount += 1
                }

                if let same = existing.first(where: { $0.identityKey == key }) {
                    update(same, from: listing)
                } else {
                    modelContext.insert(listing)
                }
            }

            // 一覧から消えた物件はローカルから削除
            for e in existing {
                if !incomingKeys.contains(e.identityKey) {
                    modelContext.delete(e)
                }
            }

            try modelContext.save()
            return SyncResult(newCount: newCount)

        } catch {
            return SyncResult(error: "\(propertyType): \(error.localizedDescription)")
        }
    }

    /// JSON 由来のプロパティのみ更新。memo / isLiked / addedAt / latitude / longitude はユーザーデータのため上書きしない。
    private func update(_ existing: Listing, from new: Listing) {
        existing.source = new.source
        existing.url = new.url
        existing.name = new.name
        existing.priceMan = new.priceMan
        existing.address = new.address
        existing.stationLine = new.stationLine
        existing.walkMin = new.walkMin
        existing.areaM2 = new.areaM2
        existing.layout = new.layout
        existing.builtStr = new.builtStr
        existing.builtYear = new.builtYear
        existing.totalUnits = new.totalUnits
        existing.floorPosition = new.floorPosition
        existing.floorTotal = new.floorTotal
        existing.floorStructure = new.floorStructure
        existing.ownership = new.ownership
        existing.listWardRoman = new.listWardRoman
        existing.fetchedAt = new.fetchedAt
        existing.propertyType = new.propertyType
        existing.priceMaxMan = new.priceMaxMan
        existing.areaMaxM2 = new.areaMaxM2
        existing.deliveryDate = new.deliveryDate
        // existing.memo, existing.isLiked, existing.addedAt, existing.latitude, existing.longitude はそのまま
    }

    private func notifyNewListings(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "新着物件"
        content.body = "\(count)件の新規物件が追加されました。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
