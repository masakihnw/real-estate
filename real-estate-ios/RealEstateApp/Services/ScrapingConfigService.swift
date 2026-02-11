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

/// スクレイピング条件（Firestore scraping_config/default と対応）
struct ScrapingConfig: Sendable {
    var priceMinMan: Int
    var priceMaxMan: Int
    var areaMinM2: Int
    var areaMaxM2: Int?
    var walkMinMax: Int
    var builtYearMin: Int
    var totalUnitsMin: Int
    var layoutPrefixOk: [String]
    var allowedLineKeywords: [String]

    /// config.py のデフォルト値
    static let defaults = ScrapingConfig(
        priceMinMan: 7500,
        priceMaxMan: 10000,
        areaMinM2: 60,
        areaMaxM2: nil,
        walkMinMax: 7,
        builtYearMin: Calendar.current.component(.year, from: Date()) - 20,
        totalUnitsMin: 50,
        layoutPrefixOk: ["2", "3"],
        allowedLineKeywords: [
            "ＪＲ", "東京メトロ", "都営",
            "東急", "京急", "京成", "東武", "西武", "小田急", "京王", "相鉄",
            "つくばエクスプレス", "モノレール", "舎人ライナー",
            "ゆりかもめ", "りんかい",
        ]
    )

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
            allowedLineKeywords: (data["allowedLineKeywords"] as? [String]) ?? []
        )
    }

    /// Firestore 用の辞書に変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "priceMinMan": priceMinMan,
            "priceMaxMan": priceMaxMan,
            "areaMinM2": areaMinM2,
            "walkMinMax": walkMinMax,
            "builtYearMin": builtYearMin,
            "totalUnitsMin": totalUnitsMin,
            "layoutPrefixOk": layoutPrefixOk,
            "allowedLineKeywords": allowedLineKeywords,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        data["areaMaxM2"] = areaMaxM2 ?? NSNull()
        return data
    }
}

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

    private init() {}

    var isAuthenticated: Bool {
        Auth.auth().currentUser != nil
    }

    /// Firestore から設定を取得
    func fetch() async {
        guard isAuthenticated else {
            lastError = "ログインが必要です"
            return
        }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let doc = try await db.collection(collectionName).document(documentId).getDocument()
            await MainActor.run {
                if doc.exists, let data = doc.data(),
                   let loaded = ScrapingConfig.from(firestoreData: data) {
                    config = loaded
                } else {
                    config = .defaults
                }
            }
        } catch {
            await MainActor.run {
                lastError = error.localizedDescription
                config = .defaults
            }
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

        var data = newConfig.toFirestoreData()
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

        await MainActor.run {
            config = newConfig
            lastError = nil
        }
    }

    /// ローカルの config を更新（UI から編集する際に使用）
    func updateConfig(_ transform: (inout ScrapingConfig) -> Void) {
        var c = config
        transform(&c)
        config = c
    }
}
