//
//  PhotoStorageService.swift
//  RealEstateApp
//
//  内見写真をアプリの Documents ディレクトリにローカル保存する。
//  画像は物件ごとのサブディレクトリに JPEG 形式で保存し、
//  メタデータ（PhotoMeta）を Listing.photosJSON に JSON 文字列として記録する。
//

import Foundation
import UIKit
import SwiftData
import CryptoKit

@Observable
final class PhotoStorageService {
    static let shared = PhotoStorageService()

    private let fileManager = FileManager.default

    /// インメモリ画像キャッシュ（NSCache はスレッドセーフ・メモリ圧でAutoEvict）
    private let imageCache = NSCache<NSString, UIImage>()

    /// 写真保存ルートディレクトリ（Documents/listing-photos/）
    /// Documents が取得できない場合は tmp にフォールバック
    private var photosRootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("listing-photos", isDirectory: true)
    }

    private init() {
        // キャッシュ設定（最大50枚 / 50MB）
        imageCache.countLimit = 50
        imageCache.totalCostLimit = 50 * 1024 * 1024

        // ルートディレクトリを作成
        do {
            try fileManager.createDirectory(at: photosRootURL, withIntermediateDirectories: true)
        } catch {
            print("[PhotoStorage] ルートディレクトリの作成に失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 物件ごとのディレクトリ

    /// identityKey から物件ごとのディレクトリ名を生成（SHA256 先頭16文字）
    private func directoryName(for identityKey: String) -> String {
        let hash = SHA256.hash(data: Data(identityKey.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 物件ごとの写真ディレクトリ URL
    private func directoryURL(for listing: Listing) -> URL {
        let dirName = directoryName(for: listing.identityKey)
        return photosRootURL.appendingPathComponent(dirName, isDirectory: true)
    }

    // MARK: - 写真の保存

    /// UIImage を物件に紐づけて保存し、Listing.photosJSON を更新する。
    @MainActor
    func savePhoto(_ image: UIImage, for listing: Listing, modelContext: ModelContext) {
        let dir = directoryURL(for: listing)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("[PhotoStorage] 物件ディレクトリの作成に失敗: \(error.localizedDescription)")
            return
        }

        let photoId = UUID().uuidString
        let fileName = "\(photoId).jpg"
        let fileURL = dir.appendingPathComponent(fileName)

        // JPEG 圧縮して保存（0.8 品質でバランス良好）
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[PhotoStorage] 写真の保存に失敗: \(error.localizedDescription)")
            return
        }

        // メタデータを更新
        var photos = listing.parsedPhotos
        photos.append(PhotoMeta(id: photoId, fileName: fileName, createdAt: .now))
        listing.photosJSON = PhotoMeta.encode(photos)
        SaveErrorHandler.shared.save(modelContext, source: "PhotoStorage")
    }

    // MARK: - 写真の読み込み

    /// 写真メタデータからファイルの URL を取得
    func photoURL(for meta: PhotoMeta, listing: Listing) -> URL {
        directoryURL(for: listing).appendingPathComponent(meta.fileName)
    }

    /// 写真メタデータから UIImage を非同期に読み込む（バックグラウンド I/O + インメモリキャッシュ）
    func loadImage(for meta: PhotoMeta, listing: Listing) async -> UIImage? {
        let cacheKey = meta.id as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        let url = photoURL(for: meta, listing: listing)
        return await Task.detached(priority: .userInitiated) { [imageCache] in
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { return nil as UIImage? }
            imageCache.setObject(image, forKey: cacheKey, cost: data.count)
            return image
        }.value
    }

    /// キャッシュから画像を即座に取得（キャッシュミス時は nil）
    func cachedImage(for meta: PhotoMeta) -> UIImage? {
        imageCache.object(forKey: meta.id as NSString)
    }

    /// キャッシュから指定写真を除去
    func evictCache(for meta: PhotoMeta) {
        imageCache.removeObject(forKey: meta.id as NSString)
    }

    // MARK: - 写真の削除

    /// 指定した写真を削除する
    @MainActor
    func deletePhoto(_ meta: PhotoMeta, for listing: Listing, modelContext: ModelContext) {
        let fileURL = photoURL(for: meta, listing: listing)
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            print("[PhotoStorage] ファイル削除失敗（メタデータは更新します）: \(error.localizedDescription)")
        }

        var photos = listing.parsedPhotos
        photos.removeAll { $0.id == meta.id }
        listing.photosJSON = photos.isEmpty ? nil : PhotoMeta.encode(photos)
        SaveErrorHandler.shared.save(modelContext, source: "PhotoStorage")
    }

    /// 物件に紐づく全写真を削除する
    @MainActor
    func deleteAllPhotos(for listing: Listing, modelContext: ModelContext) {
        let dir = directoryURL(for: listing)
        do {
            try fileManager.removeItem(at: dir)
        } catch {
            print("[PhotoStorage] ディレクトリ削除失敗: \(error.localizedDescription)")
        }

        listing.photosJSON = nil
        SaveErrorHandler.shared.save(modelContext, source: "PhotoStorage")
    }
}
