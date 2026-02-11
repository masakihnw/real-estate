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

    /// 写真保存ルートディレクトリ（Documents/listing-photos/）
    private var photosRootURL: URL {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("[PhotoStorage] Documents ディレクトリが取得できません")
        }
        return docs.appendingPathComponent("listing-photos", isDirectory: true)
    }

    private init() {
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
        do { try modelContext.save() } catch { print("[PhotoStorage] save 失敗: \(error)") }
    }

    // MARK: - 写真の読み込み

    /// 写真メタデータからファイルの URL を取得
    func photoURL(for meta: PhotoMeta, listing: Listing) -> URL {
        directoryURL(for: listing).appendingPathComponent(meta.fileName)
    }

    /// 写真メタデータから UIImage を読み込む
    /// - Note: 同期でファイル I/O を行うため、UI スレッドで大量呼び出しすると応答性が低下する可能性があります。
    ///   可能であれば呼び出し元でバックグラウンドコンテキスト（Task.detached や別スレッド）から利用してください。
    func loadImage(for meta: PhotoMeta, listing: Listing) -> UIImage? {
        let url = photoURL(for: meta, listing: listing)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
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
        do { try modelContext.save() } catch { print("[PhotoStorage] save 失敗: \(error)") }
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
        do { try modelContext.save() } catch { print("[PhotoStorage] save 失敗: \(error)") }
    }
}
