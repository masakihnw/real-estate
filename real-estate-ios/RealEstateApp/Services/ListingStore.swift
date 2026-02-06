//
//  ListingStore.swift
//  RealEstateApp
//
//  物件一覧の取得・永続化・差分検出（新規→プッシュ用）
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
    private let listURLKey = "realestate.listURL"
    private let lastFetchedKey = "realestate.lastFetchedAt"

    var listURL: String {
        get {
            defaults.string(forKey: listURLKey) ?? ""
        }
        set {
            defaults.set(newValue, forKey: listURLKey)
        }
    }

    private init() {
        lastFetchedAt = defaults.object(forKey: lastFetchedKey) as? Date
    }

    /// リモート JSON を取得し、SwiftData に反映。新規があればローカル通知を発火する。
    func refresh(modelContext: ModelContext) async {
        let urlString = listURL.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            lastError = "一覧URLを設定してください"
            return
        }

        await MainActor.run { isRefreshing = true }
        lastError = nil

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let dtos = try JSONDecoder().decode([ListingDTO].self, from: data)
            let fetchedAt = Date()

            let descriptor = FetchDescriptor<Listing>()
            let existing = try modelContext.fetch(descriptor)
            let existingKeys = Set(existing.map(\.identityKey))

            var newCount = 0
            for dto in dtos {
                guard let listing = Listing.from(dto: dto, fetchedAt: fetchedAt) else { continue }
                if !existingKeys.contains(listing.identityKey) {
                    newCount += 1
                }
                // 同一 identityKey の既存を更新 or 新規挿入
                if let same = existing.first(where: { $0.identityKey == listing.identityKey }) {
                    update(same, from: listing)
                } else {
                    modelContext.insert(listing)
                }
            }

            // 一覧から消えた物件はローカルから削除（オプション: 残す選択も可）
            for e in existing {
                let stillPresent = dtos.contains { dto in
                    guard let l = Listing.from(dto: dto, fetchedAt: fetchedAt) else { return false }
                    return l.identityKey == e.identityKey
                }
                if !stillPresent {
                    modelContext.delete(e)
                }
            }

            try modelContext.save()
            await MainActor.run {
                lastFetchedAt = fetchedAt
                defaults.set(fetchedAt, forKey: lastFetchedKey)
                isRefreshing = false
            }

            if newCount > 0 {
                await notifyNewListings(count: newCount)
            }

            // Firestore からアノテーション（いいね・メモ）を取得してマージ
            await FirebaseSyncService.shared.pullAnnotations(modelContext: modelContext)
        } catch {
            await MainActor.run {
                lastError = error.localizedDescription
                isRefreshing = false
            }
        }
    }

    /// JSON 由来のプロパティのみ更新。memo / isLiked / addedAt はユーザー入力・初回追加日のため上書きしない。
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
        // existing.memo, existing.isLiked はそのまま（同期で上書きしない）
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
