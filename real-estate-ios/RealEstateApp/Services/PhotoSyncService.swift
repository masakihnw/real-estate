//
//  PhotoSyncService.swift
//  RealEstateApp
//
//  Firebase Storage + Firestore を使って内見写真をクラウドに保存し、家族間で共有する。
//  写真データは Firebase Storage に JPEG で保存し、メタデータは Firestore の
//  annotations/{docID}.photos map に記録する。
//
//  コメントと同様の楽観的更新パターン:
//    1. ローカルに即座に保存（PhotoStorageService 経由）
//    2. バックグラウンドで Firebase Storage にアップロード
//    3. Firestore にメタデータを書き込み
//

import Foundation
import UIKit
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import SwiftData

@Observable
final class PhotoSyncService {
    static let shared = PhotoSyncService()

    /// 現在アップロード中の写真 ID セット（UI でプログレス表示に使用）
    private(set) var uploadingPhotoIds: Set<String> = []

    /// 現在ダウンロード中の写真 ID セット
    private(set) var downloadingPhotoIds: Set<String> = []

    private let storage = Storage.storage()
    private let db = Firestore.firestore()
    private let collectionName = "annotations"

    /// アップロード時の最大画像サイズ（最長辺）
    private let maxUploadDimension: CGFloat = 1920
    /// アップロード時の JPEG 圧縮品質
    private let uploadJPEGQuality: CGFloat = 0.7

    private init() {}

    // MARK: - Auth Helpers

    var isAuthenticated: Bool {
        Auth.auth().currentUser != nil
    }

    var currentUserId: String? {
        Auth.auth().currentUser?.uid
    }

    var currentUserDisplayName: String {
        Auth.auth().currentUser?.displayName ?? "不明"
    }

    // MARK: - Document ID（FirebaseSyncService と同じロジック）

    /// identityKey → Firestore ドキュメントID（SHA256 先頭16文字）
    private func documentID(for identityKey: String) -> String {
        let hash = SHA256.hash(data: Data(identityKey.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - アップロード

    /// 写真を Firebase Storage にアップロードし、Firestore にメタデータを書き込む。
    /// ローカル保存は呼び出し元（PhotoStorageService）で事前に完了していること。
    func uploadPhoto(_ image: UIImage, photoMeta: PhotoMeta, for listing: Listing, modelContext: ModelContext) {
        guard isAuthenticated, let userId = currentUserId else {
            print("[PhotoSync] 未認証のためアップロードをスキップ")
            return
        }

        let docID = documentID(for: listing.identityKey)
        let storagePath = "photos/\(docID)/\(photoMeta.id).jpg"

        // リサイズ + 圧縮
        let resized = resizeImageIfNeeded(image, maxDimension: maxUploadDimension)
        guard let jpegData = resized.jpegData(compressionQuality: uploadJPEGQuality) else {
            print("[PhotoSync] JPEG 変換に失敗")
            return
        }

        // アップロード中フラグ
        uploadingPhotoIds.insert(photoMeta.id)

        let storageRef = storage.reference().child(storagePath)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        storageRef.putData(jpegData, metadata: metadata) { [weak self] _, error in
            guard let self else { return }

            if let error {
                print("[PhotoSync] Storage アップロード失敗: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.uploadingPhotoIds.remove(photoMeta.id)
                }
                return
            }

            // Firestore にメタデータを書き込み
            let photoData: [String: Any] = [
                "fileName": photoMeta.fileName,
                "authorName": self.currentUserDisplayName,
                "authorId": userId,
                "createdAt": Timestamp(date: photoMeta.createdAt),
                "storagePath": storagePath
            ]

            self.db.collection(self.collectionName).document(docID).setData([
                "photos": [photoMeta.id: photoData],
                "updatedAt": FieldValue.serverTimestamp(),
                "name": listing.name
            ], merge: true) { error in
                if let error {
                    print("[PhotoSync] Firestore メタデータ書き込み失敗: \(error.localizedDescription)")
                }
            }

            // ローカルの PhotoMeta を更新（storagePath, authorName, authorId を記録）
            DispatchQueue.main.async {
                self.uploadingPhotoIds.remove(photoMeta.id)
                self.updateLocalPhotoMeta(
                    photoId: photoMeta.id,
                    storagePath: storagePath,
                    authorName: self.currentUserDisplayName,
                    authorId: userId,
                    listing: listing,
                    modelContext: modelContext
                )
            }
        }
    }

    /// 未アップロードの既存写真をバックグラウンドでアップロードする（マイグレーション用）。
    func uploadPendingPhotos(for listing: Listing, modelContext: ModelContext) {
        guard isAuthenticated else { return }

        let photos = listing.parsedPhotos
        let pendingPhotos = photos.filter { !$0.isUploaded }

        for meta in pendingPhotos {
            // ローカルから画像を読み込み
            Task {
                guard let image = await PhotoStorageService.shared.loadImage(for: meta, listing: listing) else {
                    print("[PhotoSync] マイグレーション: 画像の読み込みに失敗 \(meta.id)")
                    return
                }
                await MainActor.run {
                    uploadPhoto(image, photoMeta: meta, for: listing, modelContext: modelContext)
                }
            }
        }
    }

    // MARK: - 削除

    /// クラウドから写真を削除する（Storage + Firestore）。
    func deleteCloudPhoto(_ photoMeta: PhotoMeta, for listing: Listing) {
        guard isAuthenticated else { return }

        let docID = documentID(for: listing.identityKey)

        // Firebase Storage から削除
        if let storagePath = photoMeta.storagePath {
            let storageRef = storage.reference().child(storagePath)
            storageRef.delete { error in
                if let error {
                    print("[PhotoSync] Storage 削除失敗: \(error.localizedDescription)")
                }
            }
        }

        // Firestore からメタデータを削除
        db.collection(collectionName).document(docID).updateData([
            "photos.\(photoMeta.id)": FieldValue.delete(),
            "updatedAt": FieldValue.serverTimestamp()
        ]) { error in
            if let error {
                print("[PhotoSync] Firestore メタデータ削除失敗: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Pull（Firestore → ローカル）

    /// Firestore からアノテーション内の写真メタデータを取得し、
    /// 未ダウンロードの写真を Firebase Storage からダウンロードしてローカルに保存する。
    @MainActor
    func pullPhotos(for listings: [Listing], firestoreDocuments: [QueryDocumentSnapshot], docIDToListings: [String: [Listing]], modelContext: ModelContext) async {
        guard isAuthenticated else { return }

        for doc in firestoreDocuments {
            let data = doc.data()
            guard let remotePhotos = parsePhotosFromFirestore(data) else { continue }
            guard let listings = docIDToListings[doc.documentID] else { continue }

            for listing in listings {
                let localPhotos = listing.parsedPhotos
                let localPhotoIds = Set(localPhotos.map(\.id))

                // リモートにあってローカルにない写真をダウンロード
                var updatedPhotos = localPhotos
                var hasChanges = false

                for remotePhoto in remotePhotos {
                    if !localPhotoIds.contains(remotePhoto.id) {
                        // 新しい写真 → ダウンロードしてローカルに保存
                        downloadingPhotoIds.insert(remotePhoto.id)
                        if let imageData = await downloadFromStorage(storagePath: remotePhoto.storagePath) {
                            // ローカルに保存
                            PhotoStorageService.shared.saveCloudPhoto(
                                data: imageData,
                                meta: remotePhoto,
                                for: listing
                            )
                            updatedPhotos.append(remotePhoto)
                            hasChanges = true

                            // 他ユーザーの写真の場合、通知
                            if remotePhoto.authorId != currentUserId {
                                NotificationScheduleService.shared.notifyNewPhoto(
                                    authorName: remotePhoto.authorName ?? "不明",
                                    listingName: listing.name,
                                    listingIdentityKey: listing.identityKey
                                )
                            }
                        }
                        downloadingPhotoIds.remove(remotePhoto.id)
                    } else {
                        // 既存の写真 → storagePath が更新されていれば反映
                        if let index = updatedPhotos.firstIndex(where: { $0.id == remotePhoto.id }),
                           updatedPhotos[index].storagePath != remotePhoto.storagePath {
                            updatedPhotos[index].storagePath = remotePhoto.storagePath
                            updatedPhotos[index].authorName = remotePhoto.authorName
                            updatedPhotos[index].authorId = remotePhoto.authorId
                            hasChanges = true
                        }
                    }
                }

                // リモートで削除された写真をローカルからも削除
                let remotePhotoIds = Set(remotePhotos.map(\.id))
                let deletedPhotos = localPhotos.filter { photo in
                    // アップロード済みの写真がリモートから消えた → 他ユーザーが削除
                    photo.isUploaded && !remotePhotoIds.contains(photo.id)
                }
                if !deletedPhotos.isEmpty {
                    for deleted in deletedPhotos {
                        PhotoStorageService.shared.deleteLocalFile(for: deleted, listing: listing)
                        updatedPhotos.removeAll { $0.id == deleted.id }
                    }
                    hasChanges = true
                }

                if hasChanges {
                    listing.photosJSON = updatedPhotos.isEmpty ? nil : PhotoMeta.encode(updatedPhotos)
                }
            }
        }

        SaveErrorHandler.shared.save(modelContext, source: "PhotoSync")
    }

    // MARK: - Firestore パース

    /// Firestore ドキュメントの photos map を PhotoMeta 配列にパースする。
    func parsePhotosFromFirestore(_ data: [String: Any]) -> [PhotoMeta]? {
        guard let photosMap = data["photos"] as? [String: Any] else { return nil }

        var photos: [PhotoMeta] = []
        for (id, value) in photosMap {
            guard let dict = value as? [String: Any] else { continue }
            let fileName = dict["fileName"] as? String ?? "\(id).jpg"
            let createdAt = (dict["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            let authorName = dict["authorName"] as? String
            let authorId = dict["authorId"] as? String
            let storagePath = dict["storagePath"] as? String

            photos.append(PhotoMeta(
                id: id,
                fileName: fileName,
                createdAt: createdAt,
                authorName: authorName,
                authorId: authorId,
                storagePath: storagePath
            ))
        }

        return photos.isEmpty ? nil : photos
    }

    // MARK: - Private Helpers

    /// Firebase Storage から画像データをダウンロードする。
    private func downloadFromStorage(storagePath: String?) async -> Data? {
        guard let path = storagePath else { return nil }
        let ref = storage.reference().child(path)
        // 最大 10MB
        let maxSize: Int64 = 10 * 1024 * 1024

        return await withCheckedContinuation { continuation in
            ref.getData(maxSize: maxSize) { data, error in
                if let error {
                    print("[PhotoSync] Storage ダウンロード失敗: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// ローカルの PhotoMeta を更新する（アップロード完了後）。
    @MainActor
    private func updateLocalPhotoMeta(photoId: String, storagePath: String, authorName: String, authorId: String, listing: Listing, modelContext: ModelContext) {
        var photos = listing.parsedPhotos
        if let index = photos.firstIndex(where: { $0.id == photoId }) {
            photos[index].storagePath = storagePath
            photos[index].authorName = authorName
            photos[index].authorId = authorId
            listing.photosJSON = PhotoMeta.encode(photos)
            SaveErrorHandler.shared.save(modelContext, source: "PhotoSync")
        }
    }

    /// 画像を最大サイズにリサイズする（アスペクト比を保持）。
    private func resizeImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else { return image }

        let scale = maxDimension / longestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
