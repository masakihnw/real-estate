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

    /// Firestore のアノテーションを取得し、ローカル SwiftData にマージする。
    /// ローカルに存在する物件の docID のみを対象にバッチ取得する。
    @MainActor
    func pullAnnotations(modelContext: ModelContext) async {
        guard isAuthenticated else {
            print("[FirebaseSync] 未認証のため pull をスキップ")
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        do {
            // ローカルの全物件を取得し、docID → Listing のマップを構築
            let descriptor = FetchDescriptor<Listing>()
            let localListings = try modelContext.fetch(descriptor)

            var docIDToListings: [String: [Listing]] = [:]
            for listing in localListings {
                let docID = documentID(for: listing.identityKey)
                docIDToListings[docID, default: []].append(listing)
            }

            let allDocIDs = Array(docIDToListings.keys)
            guard !allDocIDs.isEmpty else { return }

            // Firestore の IN クエリは最大30件ずつ
            let batchSize = 30
            for batchStart in stride(from: 0, to: allDocIDs.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, allDocIDs.count)
                let batchIDs = Array(allDocIDs[batchStart..<batchEnd])

                let snapshot = try await db.collection(collectionName)
                    .whereField(FieldPath.documentID(), in: batchIDs)
                    .getDocuments()

                for doc in snapshot.documents {
                    let data = doc.data()
                    let isLiked = data["isLiked"] as? Bool ?? false
                    let memo = data["memo"] as? String
                    let cleanMemo = (memo?.isEmpty == true) ? nil : memo

                    guard let listings = docIDToListings[doc.documentID] else { continue }
                    for listing in listings {
                        if listing.isLiked != isLiked {
                            listing.isLiked = isLiked
                        }
                        if listing.memo != cleanMemo {
                            listing.memo = cleanMemo
                        }
                    }
                }
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
