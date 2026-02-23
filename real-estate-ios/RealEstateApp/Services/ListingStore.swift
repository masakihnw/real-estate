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
    /// 非致命的な同期警告（Firebase いいね・メモ、通勤時間計算など）。UI で任意に表示可能。
    private(set) var syncWarning: String?
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
        syncWarning = nil
        lastRefreshHadChanges = false

        // SwiftData が空の場合は ETag をクリアしてフルフェッチを強制する。
        // アプリの再インストール/リビルドで SwiftData はクリアされるが
        // UserDefaults（ETag）が残っていると 304 が返り、データが 0 件になる問題を防ぐ。
        let chukoDescriptor = FetchDescriptor<Listing>(predicate: #Predicate { $0.propertyType == "chuko" })
        let shinchikuDescriptor = FetchDescriptor<Listing>(predicate: #Predicate { $0.propertyType == "shinchiku" })
        var chukoCount = 0
        var shinchikuCount = 0
        do {
            chukoCount = try modelContext.fetchCount(chukoDescriptor)
            shinchikuCount = try modelContext.fetchCount(shinchikuDescriptor)
        } catch {
            print("[ListingStore] fetchCount 失敗: \(error.localizedDescription)")
        }
        if chukoCount == 0 || shinchikuCount == 0 {
            clearETags()
            print("[ListingStore] SwiftData が空のため ETag をクリアしてフルフェッチを実行します")
        }

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

        let bothNotModified = !chukoResult.hadChanges && chukoResult.error == nil
            && !shinResult.hadChanges && shinResult.error == nil

        // Firestore からアノテーション（いいね・メモ）を取得してマージ
        // 両ソースが304（データ変更なし）の場合はスキップ
        if !bothNotModified {
            await FirebaseSyncService.shared.pullAnnotations(modelContext: modelContext) { [self] msg in
                Task { @MainActor in
                    syncWarning = syncWarning.map { "\($0); \(msg)" } ?? msg
                }
            }
        }

        // 通勤時間の自動計算（未計算 or 7日以上経過のみ）
        await CommuteTimeService.shared.calculateForAllListings(modelContext: modelContext) { [self] msg in
            Task { @MainActor in
                syncWarning = syncWarning.map { "\($0); \(msg)" } ?? msg
            }
        }
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
            // データ未変更でも前回の isNew フラグをリセットする
            // isNew == true のものだけをフェッチして更新（全件ロード回避）
            do {
                let predicate = #Predicate<Listing> {
                    $0.propertyType == propertyType && $0.isNew == true
                }
                let descriptor = FetchDescriptor<Listing>(predicate: predicate)
                let newOnes = try modelContext.fetch(descriptor)
                if !newOnes.isEmpty {
                    for e in newOnes { e.isNew = false }
                    try modelContext.save()
                }
            } catch {
                print("[ListingStore] isNew リセット失敗 (\(propertyType)): \(error)")
            }
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

                // 前回 isNew だった物件をリセット（今回の同期で新規でなければ消える）
                for e in existing { e.isNew = false }

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
                        listing.isNew = true
                        listing.addedAt = fetchedAt
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

    /// JSON 由来のプロパティのみ更新。memo / isLiked / isNew / addedAt / latitude / longitude はユーザーデータ・同期管理データのため上書きしない。
    private func update(_ existing: Listing, from new: Listing) {
        existing.source = new.source
        existing.url = new.url
        existing.name = new.name
        existing.priceMan = new.priceMan
        existing.address = new.address
        existing.ssAddress = new.ssAddress
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
        existing.managementFee = new.managementFee
        existing.repairReserveFund = new.repairReserveFund
        existing.direction = new.direction
        existing.balconyAreaM2 = new.balconyAreaM2
        existing.parking = new.parking
        existing.constructor = new.constructor
        existing.zoning = new.zoning
        existing.repairFundOnetime = new.repairFundOnetime
        existing.featureTagsJSON = new.featureTagsJSON
        existing.listWardRoman = new.listWardRoman
        existing.fetchedAt = new.fetchedAt
        existing.propertyType = new.propertyType
        existing.duplicateCount = new.duplicateCount
        existing.priceMaxMan = new.priceMaxMan
        existing.areaMaxM2 = new.areaMaxM2
        existing.deliveryDate = new.deliveryDate
        // 間取り図画像（JSON 由来なので上書き）
        existing.floorPlanImagesJSON = new.floorPlanImagesJSON
        // SUUMO 物件写真（JSON 由来なので上書き）
        existing.suumoImagesJSON = new.suumoImagesJSON
        // ハザード情報（JSON 由来なので上書き）
        existing.hazardInfo = new.hazardInfo
        // 住まいサーフィン評価データ（JSON 由来なので上書き）
        existing.ssLookupStatus = new.ssLookupStatus
        existing.ssProfitPct = new.ssProfitPct
        existing.ssOkiPrice70m2 = new.ssOkiPrice70m2
        existing.ssM2Discount = new.ssM2Discount
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
        existing.ssLoanBalance5yr = new.ssLoanBalance5yr
        existing.ssLoanBalance10yr = new.ssLoanBalance10yr
        existing.ssNewM2Price = new.ssNewM2Price
        existing.ssForecastM2Price = new.ssForecastM2Price
        existing.ssForecastChangeRate = new.ssForecastChangeRate
        existing.ssPastMarketTrends = new.ssPastMarketTrends
        existing.ssSurroundingProperties = new.ssSurroundingProperties
        existing.ssPriceJudgments = new.ssPriceJudgments
        existing.ssSimBasePrice = new.ssSimBasePrice
        // 不動産情報ライブラリ相場データ・人口動態データ（パイプライン側で付与）
        existing.reinfolibMarketData = new.reinfolibMarketData
        existing.estatPopulationData = new.estatPopulationData
        // JSON から座標が提供されていれば更新（パイプライン側ジオコーディングの反映）
        if let lat = new.latitude { existing.latitude = lat }
        if let lon = new.longitude { existing.longitude = lon }
        // 通勤時間: パイプラインのデータを初期値として取り込む
        // 既存データがないか、フォールバック概算（経路情報取得不可）の場合のみ上書き
        // MKDirections で取得した正確な経路データは保持する
        if let pipelineCommute = new.commuteInfoJSON {
            if existing.commuteInfoJSON == nil {
                existing.commuteInfoJSON = pipelineCommute
            } else if existing.parsedCommuteInfo.hasFallbackEstimate {
                existing.commuteInfoJSON = pipelineCommute
            }
        }
        // existing.memo, existing.isLiked, existing.isNew, existing.commentsJSON, existing.photosJSON, existing.addedAt はそのまま（ユーザー・同期管理データ）
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
