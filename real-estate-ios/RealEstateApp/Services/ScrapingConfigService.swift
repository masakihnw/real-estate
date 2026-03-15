//
//  ScrapingConfigService.swift
//  RealEstateApp
//
//  スクレイピング条件を Firestore に保存・取得する。
//  設定画面で編集した条件は scraping_config/default に保存され、
//  GitHub Actions 実行時にスクレイピングツールが読み込む。
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

struct ScrapingConfigMetadata: Decodable, Sendable {
    struct Defaults: Decodable, Sendable {
        var priceMinMan: Int
        var priceMaxMan: Int
        var areaMinM2: Int
        var areaMaxM2: Int?
        var walkMinMax: Int
        var builtYearMinOffsetYears: Int
        var totalUnitsMin: Int
        var layoutPrefixOk: [String]
        var allowedLineKeywords: [String]
        var allowedStations: [String]
    }

    struct LayoutOption: Decodable, Sendable {
        var prefix: String
        var label: String
    }

    struct StationGroup: Decodable, Sendable {
        var line: String
        var stations: [String]
    }

    struct Constraints: Decodable, Sendable {
        struct IntRange: Decodable, Sendable {
            var min: Int
            var max: Int
        }

        struct BuiltYearConstraint: Decodable, Sendable {
            var min: Int
            var maxOffsetFromCurrentYear: Int
        }

        var priceMinMan: IntRange
        var priceMaxMan: IntRange
        var areaMinM2: IntRange
        var areaMaxM2: IntRange
        var walkMinMax: IntRange
        var totalUnitsMin: IntRange
        var builtYearMinOffsetYears: IntRange
        var builtYearMin: BuiltYearConstraint
    }

    var schemaVersion: Int
    var defaults: Defaults
    var layoutOptions: [LayoutOption]
    var lineKeywords: [String]
    var stationGroups: [StationGroup]
    var constraints: Constraints
    var units: [String: String]
    var uiText: [String: String]

    static let fallback = ScrapingConfigMetadata(
        schemaVersion: 1,
        defaults: Defaults(
            priceMinMan: 9000,
            priceMaxMan: 12000,
            areaMinM2: 55,
            areaMaxM2: nil,
            walkMinMax: 15,
            builtYearMinOffsetYears: 20,
            totalUnitsMin: 30,
            layoutPrefixOk: ["2", "3"],
            allowedLineKeywords: [],
            allowedStations: []
        ),
        layoutOptions: [
            LayoutOption(prefix: "1", label: "1LDK系"),
            LayoutOption(prefix: "2", label: "2LDK系"),
            LayoutOption(prefix: "3", label: "3LDK系"),
            LayoutOption(prefix: "4", label: "4LDK系"),
            LayoutOption(prefix: "5+", label: "5LDK以上"),
        ],
        lineKeywords: [
            "ＪＲ", "東京メトロ", "都営",
            "東急", "京急", "京成", "東武", "西武", "小田急", "京王", "相鉄",
            "つくばエクスプレス", "モノレール", "舎人ライナー",
            "ゆりかもめ", "りんかい",
        ],
        stationGroups: [],
        constraints: Constraints(
            priceMinMan: .init(min: 0, max: 30000),
            priceMaxMan: .init(min: 0, max: 30000),
            areaMinM2: .init(min: 1, max: 300),
            areaMaxM2: .init(min: 1, max: 300),
            walkMinMax: .init(min: 1, max: 20),
            totalUnitsMin: .init(min: 1, max: 10000),
            builtYearMinOffsetYears: .init(min: 1, max: 50),
            builtYearMin: .init(min: 1970, maxOffsetFromCurrentYear: 0)
        ),
        units: [
            "price": "万円",
            "area": "㎡",
            "totalUnits": "戸",
        ],
        uiText: [:]
    )
}

enum ScrapingConfigMetadataStore {
    static let shared: ScrapingConfigMetadata = {
        guard let url = Bundle.main.url(forResource: "ScrapingConfigMetadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ScrapingConfigMetadata.self, from: data) else {
            return .fallback
        }
        return decoded
    }()
}

/// スクレイピング条件（Firestore scraping_config/default と対応）
struct ScrapingConfig: Sendable, Equatable {
    var priceMinMan: Int
    var priceMaxMan: Int
    var areaMinM2: Int
    var areaMaxM2: Int?
    var walkMinMax: Int
    var builtYearMin: Int
    var totalUnitsMin: Int
    var layoutPrefixOk: [String]
    var allowedLineKeywords: [String]
    var allowedStations: [String]

    /// config.py と共有するデフォルト値（ScrapingConfigMetadata.json から読み込み）
    static var defaults: ScrapingConfig {
        let meta = ScrapingConfigMetadataStore.shared
        let offset = min(
            max(meta.constraints.builtYearMinOffsetYears.min, meta.defaults.builtYearMinOffsetYears),
            meta.constraints.builtYearMinOffsetYears.max
        )
        let currentYear = Calendar.current.component(.year, from: Date())
        return ScrapingConfig(
            priceMinMan: meta.defaults.priceMinMan,
            priceMaxMan: meta.defaults.priceMaxMan,
            areaMinM2: meta.defaults.areaMinM2,
            areaMaxM2: meta.defaults.areaMaxM2,
            walkMinMax: meta.defaults.walkMinMax,
            builtYearMin: currentYear - offset,
            totalUnitsMin: meta.defaults.totalUnitsMin,
            layoutPrefixOk: meta.defaults.layoutPrefixOk,
            allowedLineKeywords: meta.defaults.allowedLineKeywords,
            allowedStations: meta.defaults.allowedStations
        ).normalized(using: meta)
    }

    /// Firestore のデータから生成（Firestore は数値を NSNumber/Int64 で返すことがあるため安全に変換）
    static func from(firestoreData data: [String: Any]) -> ScrapingConfig? {
        func toInt(_ v: Any?) -> Int? {
            guard let v else { return nil }
            if let i = v as? Int { return i }
            if let i = v as? Int64 { return Int(i) }
            if let n = v as? NSNumber { return n.intValue }
            return nil
        }
        guard let priceMinMan = toInt(data["priceMinMan"]),
              let priceMaxMan = toInt(data["priceMaxMan"]),
              let areaMinM2 = toInt(data["areaMinM2"]),
              let walkMinMax = toInt(data["walkMinMax"]),
              let builtYearMin = toInt(data["builtYearMin"]),
              let totalUnitsMin = toInt(data["totalUnitsMin"]),
              let layoutArr = data["layoutPrefixOk"] as? [String] else {
            return nil
        }
        let areaMaxM2: Int? = {
            let v = data["areaMaxM2"]
            if v is NSNull || v == nil { return nil }
            return toInt(v)
        }()
        return ScrapingConfig(
            priceMinMan: priceMinMan,
            priceMaxMan: priceMaxMan,
            areaMinM2: areaMinM2,
            areaMaxM2: areaMaxM2,
            walkMinMax: walkMinMax,
            builtYearMin: builtYearMin,
            totalUnitsMin: totalUnitsMin,
            layoutPrefixOk: layoutArr,
            allowedLineKeywords: (data["allowedLineKeywords"] as? [String]) ?? [],
            allowedStations: (data["allowedStations"] as? [String]) ?? []
        ).normalized()
    }

    /// Firestore 用の辞書に変換
    func toFirestoreData() -> [String: Any] {
        let normalized = normalized()
        var data: [String: Any] = [
            "priceMinMan": normalized.priceMinMan,
            "priceMaxMan": normalized.priceMaxMan,
            "areaMinM2": normalized.areaMinM2,
            "walkMinMax": normalized.walkMinMax,
            "builtYearMin": normalized.builtYearMin,
            "totalUnitsMin": normalized.totalUnitsMin,
            "layoutPrefixOk": normalized.layoutPrefixOk,
            "allowedLineKeywords": normalized.allowedLineKeywords,
            "allowedStations": normalized.allowedStations,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        data["areaMaxM2"] = normalized.areaMaxM2 ?? NSNull()
        return data
    }

    func normalized(using metadata: ScrapingConfigMetadata = ScrapingConfigMetadataStore.shared) -> ScrapingConfig {
        let currentYear = Calendar.current.component(.year, from: Date())
        let c = metadata.constraints

        let rawPriceMin = min(max(c.priceMinMan.min, priceMinMan), c.priceMinMan.max)
        let rawPriceMax = min(max(c.priceMaxMan.min, priceMaxMan), c.priceMaxMan.max)
        let (priceMin, priceMax) = rawPriceMin <= rawPriceMax ? (rawPriceMin, rawPriceMax) : (rawPriceMax, rawPriceMin)

        let normalizedAreaMin = min(max(c.areaMinM2.min, areaMinM2), c.areaMinM2.max)
        let normalizedAreaMax: Int? = {
            guard let areaMaxM2 else { return nil }
            let clamped = min(max(c.areaMaxM2.min, areaMaxM2), c.areaMaxM2.max)
            return clamped >= normalizedAreaMin ? clamped : nil
        }()

        let normalizedWalk = min(max(c.walkMinMax.min, walkMinMax), c.walkMinMax.max)
        let maxBuiltYear = currentYear - max(0, c.builtYearMin.maxOffsetFromCurrentYear)
        let normalizedBuiltYear = min(max(c.builtYearMin.min, builtYearMin), maxBuiltYear)
        let normalizedUnits = min(max(c.totalUnitsMin.min, totalUnitsMin), c.totalUnitsMin.max)

        let defaultLayouts = metadata.defaults.layoutPrefixOk
        let uniqueLayouts = Array(NSOrderedSet(array: layoutPrefixOk.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })) as? [String] ?? []
        let layoutValues = uniqueLayouts.filter { !$0.isEmpty }.isEmpty ? defaultLayouts : uniqueLayouts.filter { !$0.isEmpty }
        let lineKeywords = (Array(NSOrderedSet(array: allowedLineKeywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })) as? [String] ?? []).filter { !$0.isEmpty }
        let stations = (Array(NSOrderedSet(array: allowedStations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })) as? [String] ?? []).filter { !$0.isEmpty }

        return ScrapingConfig(
            priceMinMan: priceMin,
            priceMaxMan: priceMax,
            areaMinM2: normalizedAreaMin,
            areaMaxM2: normalizedAreaMax,
            walkMinMax: normalizedWalk,
            builtYearMin: normalizedBuiltYear,
            totalUnitsMin: normalizedUnits,
            layoutPrefixOk: layoutValues,
            allowedLineKeywords: lineKeywords,
            allowedStations: stations
        )
    }
}

@MainActor
@Observable
final class ScrapingConfigService {
    static let shared = ScrapingConfigService()

    private let db = Firestore.firestore()
    private let collectionName = "scraping_config"
    private let documentId = "default"

    /// 現在読み込んだ設定（キャッシュ）
    private(set) var config: ScrapingConfig = .defaults
    private(set) var isLoading = false
    private(set) var lastError: String?
    private var hasLoadedOnce = false
    private var inFlightFetchTask: Task<Void, Never>?
    let metadata = ScrapingConfigMetadataStore.shared

    private init() {}

    var isAuthenticated: Bool {
        Auth.auth().currentUser != nil
    }

    /// Firestore から設定を取得（同時呼び出し時は同一タスクに合流）
    func fetch(force: Bool = false) async {
        if let task = inFlightFetchTask {
            await task.value
            return
        }
        if hasLoadedOnce && !force {
            return
        }
        let task = Task { [weak self] in
            await self?.performFetch()
        }
        inFlightFetchTask = task
        await task.value
        inFlightFetchTask = nil
    }

    private func performFetch() async {
        guard isAuthenticated else {
            lastError = "ログインが必要です"
            return
        }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let doc = try await db.collection(collectionName).document(documentId).getDocument()
            if doc.exists, let data = doc.data(),
               let loaded = ScrapingConfig.from(firestoreData: data) {
                config = loaded
            } else {
                config = .defaults
            }
            hasLoadedOnce = true
        } catch {
            lastError = error.localizedDescription
            config = .defaults
        }
    }

    /// Firestore に設定を保存
    func save(_ newConfig: ScrapingConfig) async throws {
        guard let user = Auth.auth().currentUser else {
            throw NSError(domain: "ScrapingConfigService", code: 401, userInfo: [NSLocalizedDescriptionKey: "ログインが必要です"])
        }

        // 認証トークンを強制リフレッシュ（期限切れによる permission-denied を防止）
        do {
            _ = try await user.getIDToken(forcingRefresh: true)
        } catch {
            throw NSError(domain: "ScrapingConfigService", code: 401, userInfo: [NSLocalizedDescriptionKey: "認証トークンの更新に失敗しました。再ログインしてください。"])
        }

        let normalizedConfig = newConfig.normalized(using: metadata)
        var data = normalizedConfig.toFirestoreData()
        data["updatedBy"] = user.uid
        data["updatedByName"] = user.displayName ?? user.email ?? ""

        do {
            try await db.collection(collectionName).document(documentId).setData(data, merge: true)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "FIRFirestoreErrorDomain" && nsError.code == 7 {
                // PERMISSION_DENIED
                throw NSError(domain: "ScrapingConfigService", code: 403, userInfo: [NSLocalizedDescriptionKey: "書き込み権限がありません。Firestore のセキュリティルールを確認してください。"])
            }
            throw error
        }

        config = normalizedConfig
        lastError = nil
        hasLoadedOnce = true
    }

    /// ローカルの config を更新（UI から編集する際に使用）
    func updateConfig(_ transform: (inout ScrapingConfig) -> Void) {
        var c = config
        transform(&c)
        config = c.normalized(using: metadata)
    }
}
