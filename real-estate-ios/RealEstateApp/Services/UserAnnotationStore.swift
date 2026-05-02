//
//  UserAnnotationStore.swift
//  RealEstateApp
//
//  スキーマバージョンアップ時のユーザーデータ（いいね・コメント・メモ等）の
//  バックアップ・復元を担うユーティリティ。
//
//  目的:
//    SwiftData のスキーマ変更時に DB を再作成すると全レコードが消えるが、
//    ユーザーが付けたいいね・コメント・メモ・チェックリスト・写真メタデータは
//    保持したい。このクラスは削除前に UserDefaults に保存し、
//    次回 ListingStore.syncToDatabase 実行時に identityKey で照合して復元する。
//
//  使い方:
//    // DB 削除前
//    UserAnnotationStore.backup(from: modelContext)
//    // DB 再作成・同期後（ListingStore.syncToDatabase 内部）
//    UserAnnotationStore.restore(to: listing)   // listing ごとに呼ぶ
//    UserAnnotationStore.clearBackup()           // 復元完了後に呼ぶ
//

import Foundation
import SwiftData

// MARK: - 保存するユーザーデータの構造

struct UserAnnotation: Codable {
    var isLiked: Bool
    var commentsJSON: String?
    var memo: String?
    var checklistJSON: String?
    var photosJSON: String?
    var viewedAt: Date?
}

// MARK: - UserAnnotationStore

enum UserAnnotationStore {

    private static let backupKey = "realestate.userAnnotationBackup"
    private static let defaults = UserDefaults.standard

    // MARK: - Backup

    /// SwiftData の全 Listing からユーザーデータを読み取り UserDefaults に保存する。
    /// DB 削除前に呼ぶこと。
    static func backup(from modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Listing>()
        guard let listings = try? modelContext.fetch(descriptor) else { return }

        // ユーザーデータを持つ物件のみをバックアップ
        var dict: [String: UserAnnotation] = [:]
        for listing in listings {
            let hasUserData = listing.isLiked
                || listing.commentsJSON != nil
                || listing.memo != nil
                || listing.checklistJSON != nil
                || listing.photosJSON != nil
                || listing.viewedAt != nil
            guard hasUserData else { continue }

            let annotation = UserAnnotation(
                isLiked: listing.isLiked,
                commentsJSON: listing.commentsJSON,
                memo: listing.memo,
                checklistJSON: listing.checklistJSON,
                photosJSON: listing.photosJSON,
                viewedAt: listing.viewedAt
            )
            dict[listing.identityKey] = annotation
        }

        guard !dict.isEmpty else { return }
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: backupKey)
            print("[UserAnnotationStore] \(dict.count)件のユーザーデータをバックアップしました")
        }
    }

    // MARK: - Restore

    /// 保存済みバックアップを identityKey で照合して Listing に復元する。
    /// ListingStore.syncToDatabase の新規物件挿入ループ内で呼ぶこと。
    static func restore(to listing: Listing) {
        guard let cache = loadedCache else { return }

        if let annotation = cache[listing.identityKey] {
            apply(annotation, to: listing)
            return
        }

        // 旧キー（生住所）でフォールバック — identityKey 正規化変更前のバックアップに対応
        let oldKey = [
            Listing.cleanListingName(listing.name)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression),
            (listing.layout ?? "").trimmingCharacters(in: .whitespaces),
            listing.areaM2.map { "\($0)" } ?? "",
            (listing.address ?? "").trimmingCharacters(in: .whitespaces),
            listing.builtYear.map { "\($0)" } ?? "",
            Listing.extractStationName(from: listing.stationLine ?? "")
        ].joined(separator: "|")

        if let annotation = cache[oldKey] {
            apply(annotation, to: listing)
        }
    }

    private static func apply(_ annotation: UserAnnotation, to listing: Listing) {
        if annotation.isLiked { listing.isLiked = true }
        if let v = annotation.commentsJSON, listing.commentsJSON == nil { listing.commentsJSON = v }
        if let v = annotation.memo, listing.memo == nil { listing.memo = v }
        if let v = annotation.checklistJSON, listing.checklistJSON == nil { listing.checklistJSON = v }
        if let v = annotation.photosJSON, listing.photosJSON == nil { listing.photosJSON = v }
        if let v = annotation.viewedAt { listing.viewedAt = v }
    }

    /// バックアップが存在するかどうか
    static var hasBackup: Bool {
        defaults.data(forKey: backupKey) != nil
    }

    /// バックアップを削除する（復元完了後に呼ぶ）
    static func clearBackup() {
        defaults.removeObject(forKey: backupKey)
        _loadedCache = nil
        print("[UserAnnotationStore] バックアップをクリアしました")
    }

    // MARK: - Private cache

    private static var _loadedCache: [String: UserAnnotation]?

    private static var loadedCache: [String: UserAnnotation]? {
        if let cache = _loadedCache { return cache }
        guard let data = defaults.data(forKey: backupKey),
              let dict = try? JSONDecoder().decode([String: UserAnnotation].self, from: data) else {
            return nil
        }
        _loadedCache = dict
        return dict
    }
}
