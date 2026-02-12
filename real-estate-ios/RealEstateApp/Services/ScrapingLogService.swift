//
//  ScrapingLogService.swift
//  RealEstateApp
//
//  スクレイピングパイプラインのログを Firestore から取得する。
//  Firestore ドキュメント: scraping_logs/latest
//  ログは GitHub Actions のパイプライン実行時に upload_scraping_log.py でアップロードされる。
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

/// スクレイピングログのデータモデル
struct ScrapingLog: Sendable {
    let log: String
    let status: String
    let timestamp: String
    let truncated: Bool

    /// Firestore のデータから生成
    static func from(firestoreData data: [String: Any]) -> ScrapingLog? {
        guard let log = data["log"] as? String else { return nil }
        return ScrapingLog(
            log: log,
            status: (data["status"] as? String) ?? "unknown",
            timestamp: (data["timestamp"] as? String) ?? "",
            truncated: (data["truncated"] as? Bool) ?? false
        )
    }

    /// タイムスタンプを表示用にフォーマット
    var formattedTimestamp: String {
        // ISO 8601 形式（例: 2026-02-12T06:30:00+09:00）をパース
        // Python の isoformat() はマイクロ秒付き/なしの両方を出力しうる
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFrac = ISO8601DateFormatter()
        withoutFrac.formatOptions = [.withInternetDateTime]

        if let date = withFrac.date(from: timestamp) ?? withoutFrac.date(from: timestamp) {
            let display = DateFormatter()
            display.dateFormat = "yyyy/MM/dd HH:mm:ss"
            display.timeZone = TimeZone(identifier: "Asia/Tokyo")
            return display.string(from: date)
        }
        // フォールバック: そのまま返す
        return timestamp
    }

    /// ステータスの表示テキスト
    var statusLabel: String {
        switch status {
        case "success": return "成功"
        case "error": return "エラー"
        default: return "不明"
        }
    }

    /// ステータスのアイコン
    var statusIcon: String {
        switch status {
        case "success": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    /// Cursor に共有するためのコピー用テキスト
    var copyText: String {
        var header = """
=== スクレイピングログ ===
実行日時: \(formattedTimestamp)
ステータス: \(statusLabel)
"""
        if truncated {
            header += "\n（ログが長いため一部省略）"
        }
        header += "\n===========================\n\n"
        return header + log
    }
}

@Observable
final class ScrapingLogService {
    static let shared = ScrapingLogService()

    private let db = Firestore.firestore()
    private let collectionName = "scraping_logs"
    private let documentId = "latest"

    private(set) var latestLog: ScrapingLog?
    private(set) var isLoading = false
    private(set) var lastError: String?

    private init() {}

    var isAuthenticated: Bool {
        Auth.auth().currentUser != nil
    }

    /// Firestore から最新ログを取得
    func fetch() async {
        guard isAuthenticated else {
            await MainActor.run {
                lastError = "ログインが必要です"
            }
            return
        }

        await MainActor.run {
            isLoading = true
            lastError = nil
        }

        do {
            let doc = try await db.collection(collectionName).document(documentId).getDocument()
            await MainActor.run {
                if doc.exists, let data = doc.data(),
                   let loaded = ScrapingLog.from(firestoreData: data) {
                    latestLog = loaded
                } else {
                    latestLog = nil
                    lastError = "ログがまだありません"
                }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                lastError = error.localizedDescription
                isLoading = false
            }
        }
    }
}
