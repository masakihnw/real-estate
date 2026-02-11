//
//  FirebaseSyncService.swift
//  RealEstateApp
//
//  Firestore を使って「いいね」「コメント」を家族間で共有する。
//  Google アカウント認証でログインし、annotations コレクションに読み書きする。
//  ドキュメントID = identityKey の SHA256 先頭16文字（Firestore のキー制約を回避）。
//
//  コメント: Firestore 上では { comments: { commentId: { text, authorName, authorId, createdAt } } }
//  ローカルでは Listing.commentsJSON に JSON 配列として保存。
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

    /// 現在のユーザー ID
    var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }

    /// 現在のユーザー表示名
    var currentUserDisplayName: String {
        Auth.auth().currentUser?.displayName ?? "不明"
    }

    // MARK: - いいね Push（ローカル → Firestore）

    /// いいね状態を Firestore に書き込む。
    func pushLikeState(for listing: Listing) {
        guard isAuthenticated else {
            print("[FirebaseSync] 未認証のため push をスキップ")
            return
        }
        let docID = documentID(for: listing.identityKey)
        let data: [String: Any] = [
            "isLiked": listing.isLiked,
            "updatedAt": FieldValue.serverTimestamp(),
            "name": listing.name
        ]
        db.collection(collectionName).document(docID).setData(data, merge: true) { error in
            if let error { print("[FirebaseSync] pushLikeState 書き込み失敗: \(error.localizedDescription)") }
        }
    }

    // MARK: - コメント CRUD

    /// コメントを追加する。Firestore に即座に書き込み、ローカルも楽観的に更新する。
    @MainActor
    func addComment(for listing: Listing, text: String, modelContext: ModelContext) {
        guard isAuthenticated, let user = Auth.auth().currentUser else {
            print("[FirebaseSync] 未認証のためコメント追加をスキップ")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let commentId = UUID().uuidString
        let now = Date()

        // 1. ローカルを楽観的に更新
        var comments = listing.parsedComments
        comments.append(CommentData(
            id: commentId,
            text: trimmed,
            authorName: user.displayName ?? "不明",
            authorId: user.uid,
            createdAt: now
        ))
        listing.commentsJSON = CommentData.encode(comments)
        do { try modelContext.save() } catch { print("[FirebaseSync] save 失敗: \(error)") }

        // 2. Firestore に書き込み（コメントは map 形式で保存）
        let docID = documentID(for: listing.identityKey)
        let commentData: [String: Any] = [
            "text": trimmed,
            "authorName": user.displayName ?? "不明",
            "authorId": user.uid,
            "createdAt": Timestamp(date: now)
        ]
        db.collection(collectionName).document(docID).setData([
            "comments": [commentId: commentData],
            "updatedAt": FieldValue.serverTimestamp(),
            "name": listing.name
        ], merge: true) { error in
            if let error { print("[FirebaseSync] addComment 書き込み失敗: \(error.localizedDescription)") }
        }
    }

    /// コメントを編集する。自分のコメントのみ編集可能。
    @MainActor
    func editComment(for listing: Listing, commentId: String, newText: String, modelContext: ModelContext) {
        guard isAuthenticated, let userId = currentUserId else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()

        // 1. ローカルを楽観的に更新（所有権チェック: 自分のコメントのみ）
        var comments = listing.parsedComments
        guard let index = comments.firstIndex(where: { $0.id == commentId }),
              comments[index].authorId == userId else { return }
        comments[index].text = trimmed
        comments[index].editedAt = now
        listing.commentsJSON = CommentData.encode(comments)
        do { try modelContext.save() } catch { print("[FirebaseSync] save 失敗: \(error)") }

        // 2. Firestore に書き込み
        let docID = documentID(for: listing.identityKey)
        db.collection(collectionName).document(docID).updateData([
            "comments.\(commentId).text": trimmed,
            "comments.\(commentId).editedAt": Timestamp(date: now),
            "updatedAt": FieldValue.serverTimestamp()
        ]) { error in
            if let error { print("[FirebaseSync] editComment 書き込み失敗: \(error.localizedDescription)") }
        }
    }

    /// コメントを削除する。自分のコメントのみ削除可能。
    @MainActor
    func deleteComment(for listing: Listing, commentId: String, modelContext: ModelContext) {
        guard isAuthenticated, let userId = currentUserId else { return }

        // 1. 所有権チェック: 自分のコメントのみ削除可能
        let comments = listing.parsedComments
        guard comments.contains(where: { $0.id == commentId && $0.authorId == userId }) else { return }

        // 2. ローカルを楽観的に更新
        var updatedComments = comments
        updatedComments.removeAll { $0.id == commentId }
        listing.commentsJSON = updatedComments.isEmpty ? nil : CommentData.encode(updatedComments)
        do { try modelContext.save() } catch { print("[FirebaseSync] save 失敗: \(error)") }

        // 3. Firestore から削除
        let docID = documentID(for: listing.identityKey)
        db.collection(collectionName).document(docID).updateData([
            "comments.\(commentId)": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp()
        ]) { error in
            if let error { print("[FirebaseSync] deleteComment 書き込み失敗: \(error.localizedDescription)") }
        }
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

                    // コメントをパース（新形式: map of maps）
                    let commentsJSON = parseCommentsFromFirestore(data)

                    // レガシー memo → コメントへの移行
                    let finalCommentsJSON: String?
                    if commentsJSON == nil, let memo = data["memo"] as? String, !memo.isEmpty {
                        // 旧 memo を単一コメントとして変換
                        let legacy = CommentData(
                            id: "legacy",
                            text: memo,
                            authorName: "メモ",
                            authorId: "",
                            createdAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date()
                        )
                        finalCommentsJSON = CommentData.encode([legacy])
                    } else {
                        finalCommentsJSON = commentsJSON
                    }

                    guard let listings = docIDToListings[doc.documentID] else { continue }
                    for listing in listings {
                        if listing.isLiked != isLiked {
                            listing.isLiked = isLiked
                        }
                        // コメント差分検出: 他ユーザーの新規コメントを通知
                        if listing.commentsJSON != finalCommentsJSON {
                            detectAndNotifyNewComments(
                                oldJSON: listing.commentsJSON,
                                newJSON: finalCommentsJSON,
                                listingName: listing.name,
                                listingIdentityKey: listing.identityKey
                            )
                            listing.commentsJSON = finalCommentsJSON
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

    // MARK: - コメント通知検出（責務: 差分検出 + ローカル通知トリガー）

    /// 旧コメントと新コメントを比較し、他ユーザーの新規コメントがあれば通知する。
    private func detectAndNotifyNewComments(oldJSON: String?, newJSON: String?, listingName: String, listingIdentityKey: String) {
        guard let myId = currentUserId else { return }

        let oldComments: [CommentData] = {
            guard let json = oldJSON, let data = json.data(using: .utf8) else { return [] }
            return (try? CommentData.decoder.decode([CommentData].self, from: data)) ?? []
        }()
        let newComments: [CommentData] = {
            guard let json = newJSON, let data = json.data(using: .utf8) else { return [] }
            return (try? CommentData.decoder.decode([CommentData].self, from: data)) ?? []
        }()

        let oldIDs = Set(oldComments.map(\.id))
        let addedComments = newComments.filter { !oldIDs.contains($0.id) && $0.authorId != myId }

        for comment in addedComments {
            NotificationScheduleService.shared.notifyNewComment(
                authorName: comment.authorName,
                text: comment.text,
                listingName: listingName,
                listingIdentityKey: listingIdentityKey
            )
        }
    }

    // MARK: - Firestore コメントパース

    /// Firestore ドキュメントのコメント map を CommentData 配列の JSON にパースする。
    private func parseCommentsFromFirestore(_ data: [String: Any]) -> String? {
        guard let commentsMap = data["comments"] as? [String: Any] else { return nil }

        var comments: [CommentData] = []
        for (id, value) in commentsMap {
            guard let dict = value as? [String: Any] else { continue }
            let text = dict["text"] as? String ?? ""
            let authorName = dict["authorName"] as? String ?? "不明"
            let authorId = dict["authorId"] as? String ?? ""
            let createdAt = (dict["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let editedAt = (dict["editedAt"] as? Timestamp)?.dateValue()
            comments.append(CommentData(
                id: id,
                text: text,
                authorName: authorName,
                authorId: authorId,
                createdAt: createdAt,
                editedAt: editedAt
            ))
        }

        guard !comments.isEmpty else { return nil }
        return CommentData.encode(comments)
    }
}
