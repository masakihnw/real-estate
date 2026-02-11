//
//  ListingStore.swift
//  RealEstateApp
//
//  物件一覧の取得・永続化・差分検出（新規→プッシュ用）
//  中古 (latest.json) と新築 (latest_shinchiku.json) の2ソースをサポート。
//
//  ハイブリッド改善:
//  - デフォルト URL をハードコード（初回設定不要）
//  - ETag ベース差分チェック（未変更ならダウンロードスキップ）
//

import Foundation
import SwiftData
import UserNotifications

@Observable
final class ListingStore {
    static let shared = ListingStore()

    // MARK: - デフォルト URL（GitHub raw）
    // ユーザーが未設定の場合はこの URL から自動取得する。
    // Settings 画面でカスタム URL に上書き可能。
    static let defaultChukoURL = "https://raw.githubusercontent.com/masakihnw/real-estate/main/scraping-tool/results/latest.json"
    static let defaultShinchikuURL = "https://raw.githubusercontent.com/masakihnw/real-estate/main/scraping-tool/results/latest_shinchiku.json"

    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastFetchedAt: Date?
    /// 最後の更新で新着データがあったか（ETag 判定用の表示に使う）
    private(set) var lastRefreshHadChanges = true

    /// タイムアウト付き URLSession（リクエスト30秒、リソース60秒）
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private let defaults = UserDefaults.standard
    private let chukoURLKey = "realestate.listURL"
    private let shinchikuURLKey = "realestate.shinchikuListURL"
    private let lastFetchedKey = "realestate.lastFetchedAt"
    private let chukoETagKey = "realestate.etag.chuko"
    private let shinchikuETagKey = "realestate.etag.shinchiku"

    /// 中古マンション JSON URL（空ならデフォルトを使う）
    var listURL: String {
        get { defaults.string(forKey: chukoURLKey) ?? "" }
        set { defaults.set(newValue, forKey: chukoURLKey) }
    }

    /// 新築マンション JSON URL（空ならデフォルトを使う）
    var shinchikuListURL: String {
        get { defaults.string(forKey: shinchikuURLKey) ?? "" }
        set { defaults.set(newValue, forKey: shinchikuURLKey) }
    }

    /// 実際に使用される中古 URL（カスタムが空ならデフォルト）
    var effectiveChukoURL: String {
        let custom = listURL.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? Self.defaultChukoURL : custom
    }

    /// 実際に使用される新築 URL（カスタムが空ならデフォルト）
    var effectiveShinchikuURL: String {
        let custom = shinchikuListURL.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? Self.defaultShinchikuURL : custom
    }

    /// カスタム URL を使用中かどうか
    var isUsingCustomURL: Bool {
        !listURL.trimmingCharacters(in: .whitespaces).isEmpty ||
        !shinchikuListURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private init() {
        lastFetchedAt = defaults.object(forKey: lastFetchedKey) as? Date
    }

    /// 中古・新築の両方を取得し、SwiftData に反映。新規があればローカル通知を発火。
    /// ETag チェックにより、サーバー上のデータが未変更ならダウンロードをスキップする。
    func refresh(modelContext: ModelContext) async {
        // P6: 二重実行ガード — 既に更新中なら何もしない
        guard !isRefreshing else { return }
        await MainActor.run { isRefreshing = true }
        lastError = nil
        lastRefreshHadChanges = false

        // P2: 中古・新築を並列取得（ネットワーク待ちを半減）
        // NOTE: fetchAndSync 内の SwiftData 操作は同一 modelContext なので
        //       ネットワーク取得＋デコードを並列化し、DB 書き込みは逐次実行
        let chukoURL = effectiveChukoURL
        let shinchikuURL = effectiveShinchikuURL

        // ネットワーク取得 + デコードを並列実行
        async let chukoData = fetchData(urlString: chukoURL, etagKey: chukoETagKey)
        async let shinData = fetchData(urlString: shinchikuURL, etagKey: shinchikuETagKey)

        let (chukoFetch, shinFetch) = await (chukoData, shinData)

        var totalNew = 0

        // DB 書き込みは逐次（ModelContext はスレッドセーフでないため）
        let chukoResult = syncToDatabase(
            fetchResult: chukoFetch,
            propertyType: "chuko",
            modelContext: modelContext
        )
        totalNew += chukoResult.newCount
        if chukoResult.hadChanges { lastRefreshHadChanges = true }
        if let err = chukoResult.error { lastError = err }

        let shinResult = syncToDatabase(
            fetchResult: shinFetch,
            propertyType: "shinchiku",
            modelContext: modelContext
        )
        totalNew += shinResult.newCount
        if shinResult.hadChanges { lastRefreshHadChanges = true }
        if let err = shinResult.error {
            lastError = lastError.map { "\($0); \(err)" } ?? err
        }

        let fetchedAt = Date()
        await MainActor.run {
            lastFetchedAt = fetchedAt
            defaults.set(fetchedAt, forKey: lastFetchedKey)
            isRefreshing = false
        }

        if totalNew > 0 {
            NotificationScheduleService.shared.accumulateAndReschedule(newCount: totalNew)
        }

        // Firestore からアノテーション（いいね・メモ）を取得してマージ
        await FirebaseSyncService.shared.pullAnnotations(modelContext: modelContext)
    }

    /// 保存済み ETag をクリアして次回フルフェッチを強制する
    func clearETags() {
        defaults.removeObject(forKey: chukoETagKey)
        defaults.removeObject(forKey: shinchikuETagKey)
    }

    // MARK: - Private

    private struct SyncResult {
        var newCount: Int = 0
        var hadChanges: Bool = false
        var error: String?
    }

    /// ネットワーク取得結果
    private enum FetchDataResult {
        case notModified
        case data([ListingDTO])
        case error(String)
    }

    /// ネットワーク取得 + JSON デコード（並列実行可能な純粋なデータ取得）
    private func fetchData(urlString: String, etagKey: String) async -> FetchDataResult {
        guard let url = URL(string: urlString) else {
            return .error("URL が不正です")
        }

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let savedETag = defaults.string(forKey: etagKey) {
                request.setValue(savedETag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await Self.session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 304 {
                    return .notModified
                }
                // HTTP エラーステータスのチェック（404, 403 等）
                guard (200...299).contains(httpResponse.statusCode) else {
                    return .error("サーバーエラー (HTTP \(httpResponse.statusCode))。URL を確認してください。")
                }
                if let newETag = httpResponse.value(forHTTPHeaderField: "ETag") {
                    defaults.set(newETag, forKey: etagKey)
                }
            }

            // P3: JSON デコードをバックグラウンドで実行
            let dtos = try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode([ListingDTO].self, from: data)
            }.value
            return .data(dtos)

        } catch let urlError as URLError where urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost || urlError.code == .dataNotAllowed {
            return .error("オフラインのため取得できません。接続を確認してください。")
        } catch let urlError as URLError where urlError.code == .timedOut {
            return .error("タイムアウトしました。通信環境を確認してください。")
        } catch is DecodingError {
            return .error("データ形式が不正です。JSON の構造を確認してください。")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// 取得済みデータを SwiftData に同期（ModelContext 操作のため逐次実行が必要）
    private func syncToDatabase(fetchResult: FetchDataResult, propertyType: String, modelContext: ModelContext) -> SyncResult {
        switch fetchResult {
        case .notModified:
            return SyncResult(hadChanges: false)
        case .error(let msg):
            return SyncResult(error: "\(propertyType): \(msg)")
        case .data(let dtos):
            do {
                let fetchedAt = Date()
                let predicate = #Predicate<Listing> { $0.propertyType == propertyType }
                let descriptor = FetchDescriptor<Listing>(predicate: predicate)
                let existing = try modelContext.fetch(descriptor)
                // P1: Dictionary で O(1) ルックアップ
                let existingByKey = Dictionary(existing.map { ($0.identityKey, $0) }, uniquingKeysWith: { first, _ in first })

                var newCount = 0
                var incomingKeys = Set<String>()

                for dto in dtos {
                    guard let listing = Listing.from(dto: dto, fetchedAt: fetchedAt) else { continue }
                    listing.propertyType = propertyType
                    let key = listing.identityKey
                    incomingKeys.insert(key)

                    if let same = existingByKey[key] {
                        // 再掲載された物件の掲載終了フラグを解除
                        if same.isDelisted { same.isDelisted = false }
                        update(same, from: listing)
                    } else {
                        newCount += 1
                        modelContext.insert(listing)
                    }
                }

                // JSON から消えた物件の処理
                for e in existing where !incomingKeys.contains(e.identityKey) {
                    let hasUserData = e.isLiked || e.hasComments || e.hasPhotos || !(e.memo ?? "").isEmpty
                    if hasUserData {
                        // いいね/コメント付き → 掲載終了としてマーク（お気に入りタブで残す）
                        if !e.isDelisted { e.isDelisted = true }
                    } else {
                        // それ以外 → 削除
                        modelContext.delete(e)
                    }
                }

                do {
                    try modelContext.save()
                } catch {
                    let msg = "\(propertyType): データ保存に失敗しました"
                    print("[ListingStore] SwiftData save 失敗 (\(propertyType)): \(error)")
                    Task { @MainActor in
                        SaveErrorHandler.shared.lastSaveError = msg
                        SaveErrorHandler.shared.showSaveError = true
                    }
                    return SyncResult(newCount: 0, hadChanges: false, error: msg)
                }
                return SyncResult(newCount: newCount, hadChanges: true)
            } catch {
                return SyncResult(error: "\(propertyType): \(error.localizedDescription)")
            }
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
        // ハザード情報（JSON 由来なので上書き）
        existing.hazardInfo = new.hazardInfo
        // 住まいサーフィン評価データ（JSON 由来なので上書き）
        existing.ssProfitPct = new.ssProfitPct
        existing.ssOkiPrice70m2 = new.ssOkiPrice70m2
        existing.ssValueJudgment = new.ssValueJudgment
        existing.ssStationRank = new.ssStationRank
        existing.ssWardRank = new.ssWardRank
        existing.ssSumaiSurfinURL = new.ssSumaiSurfinURL
        existing.ssAppreciationRate = new.ssAppreciationRate
        existing.ssFavoriteCount = new.ssFavoriteCount
        existing.ssPurchaseJudgment = new.ssPurchaseJudgment
        existing.ssRadarData = new.ssRadarData
        existing.ssSimBest5yr = new.ssSimBest5yr
        existing.ssSimBest10yr = new.ssSimBest10yr
        existing.ssSimStandard5yr = new.ssSimStandard5yr
        existing.ssSimStandard10yr = new.ssSimStandard10yr
        existing.ssSimWorst5yr = new.ssSimWorst5yr
        existing.ssSimWorst10yr = new.ssSimWorst10yr
        // JSON から座標が提供されていれば更新（パイプライン側ジオコーディングの反映）
        if let lat = new.latitude { existing.latitude = lat }
        if let lon = new.longitude { existing.longitude = lon }
        // existing.memo, existing.isLiked, existing.commentsJSON, existing.photosJSON, existing.addedAt, existing.commuteInfoJSON はそのまま（ユーザーデータ）
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[ListingStore] 通知許可エラー: \(error.localizedDescription)")
            } else {
                print("[ListingStore] 通知許可: \(granted ? "許可" : "拒否")")
            }
        }
    }
}
