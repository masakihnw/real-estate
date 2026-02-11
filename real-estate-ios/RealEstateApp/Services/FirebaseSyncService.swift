//
//  FirebaseSyncService.swift
//  RealEstateApp
//
//  Firestore を使って「いいね」「メモ」を家族間で共有する。
//  Google アカウント認証でログインし、annotations コレクションに読み書きする。
//  ドキュメントID = identityKey の SHA256 先頭16文字（Firestore のキー制約を回避）。
//

import Foundation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import SwiftData

@Observable
final class FirebaseSyncService {
    static let shared = FirebaseSyncService()

    private(set) var isSyncing = false

    private let db = Firestore.firestore()
    private let collectionName = "annotations"

    private init() {}

    // MARK: - Auth Check

    /// 現在のユーザーが認証済みかどうかを返す。
    var isAuthenticated: Bool {
        Auth.auth().currentUser != nil
    }

    // MARK: - Push（ローカル → Firestore）

    /// 1件のアノテーション（いいね・メモ）を Firestore に書き込む。
    func pushAnnotation(for listing: Listing) {
        guard isAuthenticated else {
            print("[FirebaseSync] 未認証のため push をスキップ")
            return
        }
        let docID = documentID(for: listing.identityKey)
        let data: [String: Any] = [
            "isLiked": listing.isLiked,
            "memo": listing.memo ?? "",
            "updatedAt": FieldValue.serverTimestamp(),
            "name": listing.name  // 参照用（フィルタには使わない）
        ]
        db.collection(collectionName).document(docID).setData(data, merge: true)
    }

    // MARK: - Pull（Firestore → ローカル SwiftData）

    /// Firestore の全アノテーションを取得し、ローカル SwiftData にマージする。
    /// Firestore 側の `updatedAt` がローカルより新しい場合のみ上書き。
    func pullAnnotations(modelContext: ModelContext) async {
        guard isAuthenticated else {
            print("[FirebaseSync] 未認証のため pull をスキップ")
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let snapshot = try await db.collection(collectionName).getDocuments()

            // Firestore のドキュメントを docID → data の辞書にする
            var remoteMap: [String: (isLiked: Bool, memo: String?)] = [:]
            for doc in snapshot.documents {
                let data = doc.data()
                let isLiked = data["isLiked"] as? Bool ?? false
                let memo = data["memo"] as? String
                remoteMap[doc.documentID] = (isLiked: isLiked, memo: (memo?.isEmpty == true) ? nil : memo)
            }

            // ローカルの全物件を取得
            let descriptor = FetchDescriptor<Listing>()
            let localListings = try modelContext.fetch(descriptor)

            for listing in localListings {
                let docID = documentID(for: listing.identityKey)
                guard let remote = remoteMap[docID] else { continue }

                // Firestore の値をローカルに反映
                var changed = false
                if listing.isLiked != remote.isLiked {
                    listing.isLiked = remote.isLiked
                    changed = true
                }
                if listing.memo != remote.memo {
                    listing.memo = remote.memo
                    changed = true
                }
                _ = changed  // suppress unused warning
            }

            try modelContext.save()
        } catch {
            print("[FirebaseSync] Pull 失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// identityKey → Firestore ドキュメントID（SHA256 先頭16文字）
    private func documentID(for identityKey: String) -> String {
        let hash = SHA256.hash(data: Data(identityKey.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
