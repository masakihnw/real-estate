//
//  SupabaseAnnotationService.swift
//  RealEstateApp
//
//  Supabase RPC 経由でアノテーション（いいね・コメント）を読み書きする。
//  FirebaseSyncService の Supabase 版。useSupabase フラグで切り替え。
//
//  認証: Firebase Auth UID をそのまま user_id (TEXT) として使用。
//  Supabase 側は SECURITY DEFINER の RPC 関数でアクセスを制御。
//

import Foundation
import FirebaseAuth
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "SupabaseAnnotation")

@Observable
final class SupabaseAnnotationService {
    static let shared = SupabaseAnnotationService()

    private(set) var isSyncing = false

    private let client = SupabaseClient.shared
    private let defaults = UserDefaults.standard
    private let lastSyncKey = "supabase.annotations.lastSync"

    private init() {}

    // MARK: - Auth

    var isAuthenticated: Bool {
        Auth.auth().currentUser != nil
    }

    var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }

    var currentUserDisplayName: String {
        Auth.auth().currentUser?.displayName ?? "不明"
    }

    // MARK: - Push: いいね

    func pushLikeState(for listing: Listing) {
        guard let userId = currentUserId else { return }

        Task {
            do {
                let params: [String: Any] = [
                    "p_user_id": userId,
                    "p_identity_key": listing.identityKey,
                    "p_is_liked": listing.isLiked,
                    "p_name": listing.name
                ]
                _ = try await client.rpc("upsert_annotation", params: params)
            } catch {
                logger.error("pushLikeState 失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Push: コメント追加

    @MainActor
    func addComment(for listing: Listing, text: String, modelContext: ModelContext) {
        guard let user = Auth.auth().currentUser else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let commentId = UUID().uuidString
        let now = Date()

        // 楽観的ローカル更新
        var comments = listing.parsedComments
        comments.append(CommentData(
            id: commentId,
            text: trimmed,
            authorName: user.displayName ?? "不明",
            authorId: user.uid,
            createdAt: now
        ))
        listing.commentsJSON = CommentData.encode(comments)
        SaveErrorHandler.shared.save(modelContext, source: "SupabaseAnnotation")

        // Supabase に push
        pushComments(for: listing)
    }

    // MARK: - Push: コメント編集

    @MainActor
    func editComment(for listing: Listing, commentId: String, newText: String, modelContext: ModelContext) {
        guard let userId = currentUserId else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var comments = listing.parsedComments
        guard let index = comments.firstIndex(where: { $0.id == commentId }),
              comments[index].authorId == userId else { return }

        comments[index].text = trimmed
        comments[index].editedAt = Date()
        listing.commentsJSON = CommentData.encode(comments)
        SaveErrorHandler.shared.save(modelContext, source: "SupabaseAnnotation")

        pushComments(for: listing)
    }

    // MARK: - Push: コメント削除

    @MainActor
    func deleteComment(for listing: Listing, commentId: String, modelContext: ModelContext) {
        guard let userId = currentUserId else { return }

        var comments = listing.parsedComments
        guard comments.contains(where: { $0.id == commentId && $0.authorId == userId }) else { return }

        comments.removeAll { $0.id == commentId }
        listing.commentsJSON = comments.isEmpty ? nil : CommentData.encode(comments)
        SaveErrorHandler.shared.save(modelContext, source: "SupabaseAnnotation")

        pushComments(for: listing)
    }

    // MARK: - Pull: 全アノテーション取得

    @MainActor
    func pullAnnotations(modelContext: ModelContext, onError: ((String) -> Void)? = nil) async {
        guard isAuthenticated else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            // 全ユーザーのアノテーションを差分取得（家族共有のため）
            let annotations: [[String: Any]]
            let lastSync = defaults.string(forKey: lastSyncKey)

            if let lastSync = lastSync {
                let data = try await client.rpc("get_annotations_since", params: ["p_since": lastSync])
                annotations = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            } else {
                // 初回: 全件取得（identity_keys を渡す方式は物件が多すぎるので全件で）
                let data = try await client.rpc("get_annotations_since", params: ["p_since": "1970-01-01T00:00:00Z"])
                annotations = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            }

            guard !annotations.isEmpty else {
                defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: lastSyncKey)
                return
            }

            // identity_key でグループ化
            var annotationsByKey: [String: [[String: Any]]] = [:]
            for ann in annotations {
                guard let key = ann["listing_identity_key"] as? String else { continue }
                annotationsByKey[key, default: []].append(ann)
            }

            // ローカル物件を取得
            let descriptor = FetchDescriptor<Listing>()
            let localListings = try modelContext.fetch(descriptor)
            let listingsByKey = Dictionary(localListings.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })

            let myUserId = currentUserId

            for (identityKey, anns) in annotationsByKey {
                guard let listing = listingsByKey[identityKey] else { continue }

                // いいね: 全ユーザーのうち一人でも liked なら true
                let isLikedByAnyone = anns.contains { ($0["is_liked"] as? Bool) == true }
                if listing.isLiked != isLikedByAnyone {
                    listing.isLiked = isLikedByAnyone
                }

                // コメント: 全ユーザーのコメントをマージ
                var allComments: [CommentData] = []
                for ann in anns {
                    if let commentsJSON = ann["comments"] {
                        let parsed = parseCommentsFromJSON(commentsJSON)
                        allComments.append(contentsOf: parsed)
                    }
                }

                if !allComments.isEmpty {
                    let unique = Dictionary(allComments.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
                    allComments = Array(unique.values).sorted { $0.createdAt < $1.createdAt }
                    let newJSON = CommentData.encode(allComments)

                    if listing.commentsJSON != newJSON {
                        detectAndNotifyNewComments(
                            oldJSON: listing.commentsJSON,
                            newJSON: newJSON,
                            myUserId: myUserId,
                            listingName: listing.name,
                            listingIdentityKey: listing.identityKey
                        )
                        listing.commentsJSON = newJSON
                    }
                }
            }

            SaveErrorHandler.shared.save(modelContext, source: "SupabaseAnnotation")
            defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: lastSyncKey)

        } catch {
            logger.error("pullAnnotations 失敗: \(error.localizedDescription, privacy: .public)")
            onError?("Supabase アノテーション同期失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func pushComments(for listing: Listing) {
        guard let userId = currentUserId else { return }

        Task {
            do {
                // コメントを JSONB として送信
                let commentsParam: Any
                if let json = listing.commentsJSON,
                   let data = json.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) {
                    commentsParam = arr
                } else {
                    commentsParam = NSNull()
                }

                let params: [String: Any] = [
                    "p_user_id": userId,
                    "p_identity_key": listing.identityKey,
                    "p_comments": commentsParam,
                    "p_name": listing.name
                ]
                _ = try await client.rpc("upsert_annotation", params: params)
            } catch {
                logger.error("pushComments 失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func parseCommentsFromJSON(_ value: Any) -> [CommentData] {
        let data: Data
        if let jsonData = value as? Data {
            data = jsonData
        } else if let str = value as? String, let strData = str.data(using: .utf8) {
            data = strData
        } else if let arr = value as? [[String: Any]] {
            guard let jsonData = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
            data = jsonData
        } else {
            return []
        }
        return (try? CommentData.decoder.decode([CommentData].self, from: data)) ?? []
    }

    private func detectAndNotifyNewComments(
        oldJSON: String?,
        newJSON: String?,
        myUserId: String?,
        listingName: String,
        listingIdentityKey: String
    ) {
        guard let myId = myUserId else { return }

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
}
