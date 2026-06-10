//
//  ListingStore.swift
//  RealEstateApp
//
//  物件一覧の取得・永続化・差分検出（新規→プッシュ用）
//  デフォルトは Supabase モード。JSON フォールバックはカスタム URL 設定時のみ。
//

import Foundation
import OSLog
import SwiftData
import UserNotifications

private let logger = Logger(subsystem: "com.realestate", category: "ListingStore")

@Observable
final class ListingStore {
    static let shared = ListingStore()

    // MARK: - データソース切り替え
    private let useSupabaseKey = "realestate.useSupabase"
    var useSupabase: Bool {
        get { defaults.object(forKey: useSupabaseKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: useSupabaseKey) }
    }

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

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let defaults = UserDefaults.standard
    private let chukoURLKey = "realestate.listURL"
    private let lastFetchedKey = "realestate.lastFetchedAt"
    private let chukoETagKey = "realestate.etag.chuko"

    /// 中古マンション JSON URL（空ならデフォルトを使う）
    var listURL: String {
        get { defaults.string(forKey: chukoURLKey) ?? "" }
        set { defaults.set(newValue, forKey: chukoURLKey) }
    }

    /// レガシー互換: shinchikuListURL プロパティ（設定画面で参照される可能性）
    var shinchikuListURL: String {
        get { "" }
        set { }
    }

    /// 実際に使用される中古 URL（カスタム URL が必要。Supabase がデフォルト）
    var effectiveChukoURL: String {
        listURL.trimmingCharacters(in: .whitespaces)
    }

    /// カスタム URL を使用中かどうか
    var isUsingCustomURL: Bool {
        !listURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private init() {
        lastFetchedAt = defaults.object(forKey: lastFetchedKey) as? Date
    }

    /// サイレントプッシュ等の外部同期完了後に lastFetchedAt を更新し、
    /// フォアグラウンド復帰時の重複リフレッシュを防ぐ。
    @MainActor
    func markFetched() {
        let now = Date()
        lastFetchedAt = now
        defaults.set(now, forKey: lastFetchedKey)
    }

    /// 中古・新築の両方を取得し、SwiftData に反映。新規があればローカル通知を発火。
    /// ETag チェックにより、サーバー上のデータが未変更ならダウンロードをスキップする。
    /// - Parameter isBackground: バックグラウンドタスクからの呼び出し時は true。通勤時間計算など重い処理をスキップする。
    func refresh(modelContext: ModelContext, isBackground: Bool = false) async {
        // P6: 二重実行ガード — 既に更新中なら何もしない
        guard !isRefreshing else { return }
        await MainActor.run { isRefreshing = true }
        await performRefresh(modelContext: modelContext, isBackground: isBackground)
        // 早期 return・throw・タスクキャンセルのどの経路でも必ずここでリセットする。
        // 経路ごとに個別リセットすると漏れた経路で isRefreshing が立ちっぱなしになり、
        // 二重実行ガードにより以後リフレッシュ不能になる
        await MainActor.run { isRefreshing = false }
    }

    private func performRefresh(modelContext: ModelContext, isBackground: Bool) async {
        lastError = nil
        syncWarning = nil
        lastRefreshHadChanges = false

        // Supabase モードの場合は SupabaseListingStore に委譲
        if useSupabase {
            await refreshFromSupabase(modelContext: modelContext, isBackground: isBackground)
            return
        }

        // SwiftData が空の場合は ETag をクリアしてフルフェッチを強制する。
        // アプリの再インストール/リビルドで SwiftData はクリアされるが
        // UserDefaults（ETag）が残っていると 304 が返り、データが 0 件になる問題を防ぐ。
        let chukoDescriptor = FetchDescriptor<Listing>(predicate: #Predicate { $0.propertyType == "chuko" })
        var chukoCount = 0
        do {
            chukoCount = try modelContext.fetchCount(chukoDescriptor)
        } catch {
            logger.error("fetchCount 失敗: \(error.localizedDescription, privacy: .public)")
        }
        if chukoCount == 0 {
            clearETags()
            logger.info("SwiftData が空のため ETag をクリアしてフルフェッチを実行します")
        }

        let chukoURL = effectiveChukoURL
        let chukoFetch = await fetchData(urlString: chukoURL, etagKey: chukoETagKey)

        var totalNew = 0

        let chukoResult = syncToDatabase(
            fetchResult: chukoFetch,
            propertyType: "chuko",
            modelContext: modelContext
        )
        totalNew += chukoResult.newCount
        if chukoResult.hadChanges { lastRefreshHadChanges = true }
        if let err = chukoResult.error { lastError = err }

        let fetchedAt = Date()
        await MainActor.run {
            lastFetchedAt = fetchedAt
            defaults.set(fetchedAt, forKey: lastFetchedKey)
        }

        if totalNew > 0 {
            NotificationScheduleService.shared.accumulateAndReschedule(newCount: totalNew)
        }

        // バックグラウンド時はアノテーション同期・通勤時間計算をスキップ（実行時間制限のため）
        if !isBackground {
            let bothNotModified = !chukoResult.hadChanges && chukoResult.error == nil

            // アノテーション（いいね・コメント）を取得してマージ
            // 両ソースが304（データ変更なし）の場合はスキップ
            if !bothNotModified {
                await SupabaseAnnotationService.shared.pushAllLocalAnnotationsIfNeeded(modelContext: modelContext)
                await SupabaseAnnotationService.shared.pullAnnotations(modelContext: modelContext) { [self] msg in
                    Task { @MainActor in
                        syncWarning = syncWarning.map { "\($0); \(msg)" } ?? msg
                    }
                }
            }

            // 通勤時間計算を低優先度で遅延実行（起動時のフリーズ防止）
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(5))
                await CommuteTimeService.shared.calculateForAllListings(modelContext: modelContext) { [self] msg in
                    Task { @MainActor in
                        syncWarning = syncWarning.map { "\($0); \(msg)" } ?? msg
                    }
                }
            }
        }

        // P6: WidgetKit ウィジェット用データを App Group に書き込み
        do {
            let descriptor = FetchDescriptor<Listing>()
            let listings = try modelContext.fetch(descriptor)
            let active = listings.filter { !$0.isDelisted }
            WidgetDataProvider.update(
                totalListings: active.count,
                newListings: active.filter { $0.isRecentlyAdded }.count,
                likedCount: listings.filter { $0.isLiked }.count,
                priceChanges: 0,
                likedSummaries: listings.filter { $0.isLiked }.prefix(5).map { ($0.name, $0.priceMan, nil) }
            )
            // P6: Spotlight インデックスをいいね済み物件で再構築
            SpotlightIndexer.reindexAll(listings)
        } catch {
            logger.error("WidgetDataProvider 更新失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 保存済み ETag をクリアして次回フルフェッチを強制する
    func clearETags() {
        defaults.removeObject(forKey: chukoETagKey)
        SupabaseListingStore.shared.clearSyncState()
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
                    for e in newOnes {
                        e.isNew = false
                        e.isNewBuilding = false
                        e.isRelisted = false
                    }
                    try modelContext.save()
                }
            } catch {
                logger.error("isNew リセット失敗 (\(propertyType, privacy: .public)): \(error.localizedDescription, privacy: .public)")
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
                for e in existing {
                    e.isNew = false
                    e.isNewBuilding = false
                    e.isRelisted = false
                }

                var newCount = 0
                var incomingKeys = Set<String>()

                let hasAnnotationBackup = UserAnnotationStore.hasBackup

                for dto in dtos {
                    guard let listing = Listing.from(dto: dto, fetchedAt: fetchedAt) else { continue }
                    listing.propertyType = propertyType
                    let key = listing.identityKey
                    incomingKeys.insert(key)

                    if let same = existingByKey[key] {
                        if same.isDelisted {
                            same.isDelisted = false
                            same.isRelisted = true
                            same.addedAt = fetchedAt
                        }
                        update(same, from: listing)
                    } else {
                        // listing.isNew は DTO の is_new（サーバーサイド判定）を引き継いでいる
                        if listing.isNew { newCount += 1 }
                        // first_seen_at（サーバーサイドの初回検出日）があれば addedAt に使う。
                        // スキーマリセット後も正しい追加日順ソートを維持するため。
                        if let seen = listing.firstSeenAt,
                           let parsed = Self.isoDateFormatter.date(from: seen) {
                            listing.addedAt = parsed
                        } else {
                            listing.addedAt = fetchedAt
                        }
                        // スキーマリセット後のユーザーデータ復元（いいね・コメント・メモ等）
                        if hasAnnotationBackup {
                            UserAnnotationStore.restore(to: listing)
                        }
                        modelContext.insert(listing)
                    }
                }

                // 全物件の復元が完了したらバックアップを削除
                if hasAnnotationBackup {
                    UserAnnotationStore.clearBackup()
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
                    logger.error("SwiftData save 失敗 (\(propertyType, privacy: .public)): \(error.localizedDescription, privacy: .public)")
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
        existing.supabaseIdentityKey = new.supabaseIdentityKey ?? existing.supabaseIdentityKey
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
        existing.normalizedName = new.normalizedName
        // 住まいサーフィンスカラー値（軽量ビューに含まれるので常に更新）
        existing.ssLookupStatus = new.ssLookupStatus ?? existing.ssLookupStatus
        existing.ssProfitPct = new.ssProfitPct ?? existing.ssProfitPct
        existing.ssOkiPrice70m2 = new.ssOkiPrice70m2 ?? existing.ssOkiPrice70m2
        existing.ssM2Discount = new.ssM2Discount ?? existing.ssM2Discount
        existing.ssValueJudgment = new.ssValueJudgment ?? existing.ssValueJudgment
        existing.ssStationRank = new.ssStationRank ?? existing.ssStationRank
        existing.ssWardRank = new.ssWardRank ?? existing.ssWardRank
        existing.ssSumaiSurfinURL = new.ssSumaiSurfinURL ?? existing.ssSumaiSurfinURL
        existing.ssAppreciationRate = new.ssAppreciationRate ?? existing.ssAppreciationRate
        existing.ssFavoriteCount = new.ssFavoriteCount ?? existing.ssFavoriteCount
        existing.ssPurchaseJudgment = new.ssPurchaseJudgment ?? existing.ssPurchaseJudgment
        existing.ssSimBest5yr = new.ssSimBest5yr ?? existing.ssSimBest5yr
        existing.ssSimBest10yr = new.ssSimBest10yr ?? existing.ssSimBest10yr
        existing.ssSimStandard5yr = new.ssSimStandard5yr ?? existing.ssSimStandard5yr
        existing.ssSimStandard10yr = new.ssSimStandard10yr ?? existing.ssSimStandard10yr
        existing.ssSimWorst5yr = new.ssSimWorst5yr ?? existing.ssSimWorst5yr
        existing.ssSimWorst10yr = new.ssSimWorst10yr ?? existing.ssSimWorst10yr
        existing.ssLoanBalance5yr = new.ssLoanBalance5yr ?? existing.ssLoanBalance5yr
        existing.ssLoanBalance10yr = new.ssLoanBalance10yr ?? existing.ssLoanBalance10yr
        existing.ssNewM2Price = new.ssNewM2Price ?? existing.ssNewM2Price
        existing.ssForecastM2Price = new.ssForecastM2Price ?? existing.ssForecastM2Price
        existing.ssForecastChangeRate = new.ssForecastChangeRate ?? existing.ssForecastChangeRate
        existing.ssSimBasePrice = new.ssSimBasePrice ?? existing.ssSimBasePrice
        // JSON から座標が提供されていれば更新（パイプライン側ジオコーディングの反映）
        if let lat = new.latitude { existing.latitude = lat }
        if let lon = new.longitude { existing.longitude = lon }
        // 投資判断支援スカラー値（軽量ビューに含まれる）
        existing.firstSeenAt = new.firstSeenAt ?? existing.firstSeenAt
        existing.priceFairnessScore = new.priceFairnessScore ?? existing.priceFairnessScore
        existing.resaleLiquidityScore = new.resaleLiquidityScore ?? existing.resaleLiquidityScore
        existing.competingListingsCount = new.competingListingsCount ?? existing.competingListingsCount
        existing.listingScore = new.listingScore ?? existing.listingScore
        existing.assetGrade = new.assetGrade ?? existing.assetGrade
        existing.aiScoringReasoningJSON = new.aiScoringReasoningJSON ?? existing.aiScoringReasoningJSON
        existing.highlightBadge = new.highlightBadge ?? existing.highlightBadge
        existing.bestThumbnailURL = new.bestThumbnailURL ?? existing.bestThumbnailURL
        existing.dedupConfidence = new.dedupConfidence ?? existing.dedupConfidence
        existing.keyStrengthsJSON = new.keyStrengthsJSON ?? existing.keyStrengthsJSON
        existing.keyRisksJSON = new.keyRisksJSON ?? existing.keyRisksJSON
        existing.aiRecommendationScore = new.aiRecommendationScore ?? existing.aiRecommendationScore
        existing.aiRecommendationSummary = new.aiRecommendationSummary ?? existing.aiRecommendationSummary
        existing.aiRecommendationFlagsJSON = new.aiRecommendationFlagsJSON ?? existing.aiRecommendationFlagsJSON
        existing.aiRecommendationAction = new.aiRecommendationAction ?? existing.aiRecommendationAction
        // サーバー側画像有無フラグ（軽量ビューに含まれる boolean）
        if new.hasFloorPlanImagesServer { existing.hasFloorPlanImagesServer = true }
        if new.hasPropertyImagesServer { existing.hasPropertyImagesServer = true }
        // Enrichment JSONB フィールド（軽量ビューに含まれない → nil なら既存値を保持）
        existing.floorPlanImagesJSON = new.floorPlanImagesJSON ?? existing.floorPlanImagesJSON
        existing.suumoImagesJSON = new.suumoImagesJSON ?? existing.suumoImagesJSON
        existing.hazardInfo = new.hazardInfo ?? existing.hazardInfo
        existing.ssRadarData = new.ssRadarData ?? existing.ssRadarData
        existing.ssPastMarketTrends = new.ssPastMarketTrends ?? existing.ssPastMarketTrends
        existing.ssSurroundingProperties = new.ssSurroundingProperties ?? existing.ssSurroundingProperties
        existing.ssPriceJudgments = new.ssPriceJudgments ?? existing.ssPriceJudgments
        existing.reinfolibMarketData = new.reinfolibMarketData ?? existing.reinfolibMarketData
        existing.mansionReviewData = new.mansionReviewData ?? existing.mansionReviewData
        existing.estatPopulationData = new.estatPopulationData ?? existing.estatPopulationData
        existing.priceHistoryJSON = new.priceHistoryJSON ?? existing.priceHistoryJSON
        existing.altSourcesJSON = new.altSourcesJSON ?? existing.altSourcesJSON
        existing.investmentSummary = new.investmentSummary ?? existing.investmentSummary
        existing.extractedFeaturesJSON = new.extractedFeaturesJSON ?? existing.extractedFeaturesJSON
        existing.imageCategoriesJSON = new.imageCategoriesJSON ?? existing.imageCategoriesJSON
        existing.dedupCandidatesJSON = new.dedupCandidatesJSON ?? existing.dedupCandidatesJSON
        // 通勤時間（パイプラインデータがあれば更新、なければ既存を保持）
        if let pipelineCommute = new.commuteInfoJSON {
            let pipelineInfo = Listing._parseCommuteInfo(pipelineCommute)
            if pipelineInfo.hasAnyReliableData {
                existing.commuteInfoJSON = pipelineCommute
            } else if existing.commuteInfoJSON == nil {
                existing.commuteInfoJSON = pipelineCommute
            } else if existing.parsedCommuteInfo.hasFallbackEstimate {
                existing.commuteInfoJSON = pipelineCommute
            }
        }
        if let pipelineCommuteV2 = new.commuteInfoV2JSON {
            existing.commuteInfoV2JSON = pipelineCommuteV2
        }
    }

    /// SupabaseListingStore から呼ばれる public 版 update（同じロジック）
    func updateFromSupabase(_ existing: Listing, from new: Listing) {
        update(existing, from: new)
    }

    /// Supabase 経由でデータ取得・同期
    private func refreshFromSupabase(modelContext: ModelContext, isBackground: Bool = false) async {
        do {
            await BuildingPreferenceStore.shared.fetch()
            let (chukoNew, _) = try await SupabaseListingStore.shared.refresh(modelContext: modelContext)
            let totalNew = chukoNew
            lastRefreshHadChanges = totalNew > 0

            let fetchedAt = Date()
            await MainActor.run {
                lastFetchedAt = fetchedAt
                defaults.set(fetchedAt, forKey: lastFetchedKey)
            }

            if totalNew > 0 {
                NotificationScheduleService.shared.accumulateAndReschedule(newCount: totalNew)
            }

            // バックグラウンド時はアノテーション同期・通勤時間計算をスキップ（実行時間制限のため）
            guard !isBackground else { return }

            // アノテーション同期（Supabase 初回はローカルデータを push してから pull）
            await SupabaseAnnotationService.shared.pushAllLocalAnnotationsIfNeeded(modelContext: modelContext)
            await SupabaseAnnotationService.shared.pullAnnotations(modelContext: modelContext) { [self] msg in
                Task { @MainActor in
                    syncWarning = syncWarning.map { "\($0); \(msg)" } ?? msg
                }
            }

            // 通勤時間計算を低優先度で遅延実行（起動時のフリーズ防止）
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(5))
                await CommuteTimeService.shared.calculateForAllListings(modelContext: modelContext) { [self] msg in
                    Task { @MainActor in
                        syncWarning = syncWarning.map { "\($0); \(msg)" } ?? msg
                    }
                }
            }
        } catch {
            let detail: String
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .typeMismatch(let type, let ctx):
                    detail = "型不一致: \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
                case .valueNotFound(let type, let ctx):
                    detail = "値なし: \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
                case .keyNotFound(let key, _):
                    detail = "キーなし: \(key.stringValue)"
                case .dataCorrupted(let ctx):
                    detail = "データ破損: \(ctx.debugDescription)"
                @unknown default:
                    detail = error.localizedDescription
                }
            } else {
                detail = String(describing: error)
            }
            await MainActor.run {
                lastError = detail
            }
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                logger.error("通知許可エラー: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("通知許可: \(granted ? "許可" : "拒否", privacy: .public)")
            }
        }
    }
}
