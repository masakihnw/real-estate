import Foundation
import FirebaseAuth
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "DailyBrief")

/// AIデイリーブリーフ（buyer_daily_briefs テーブル）。
/// 生成はリポジトリ外の日次ルーチン（Routine 2）が行い、iOS は読むだけ。
struct DailyBrief: Equatable {
    /// "yyyy-MM-dd"（JST 基準の生成日）
    let briefDate: String
    let summaryText: String
    let marketInsights: String?
}

/// buyer_daily_briefs の読み取りサービス。
///
/// 取得失敗・当日分なし（鮮度切れ）の場合、呼び出し側は TodayDigest の
/// ローカル合成文にフォールバックする。パースと鮮度判定は純関数として
/// 公開しテスト可能にしている。
enum DailyBriefService {

    /// 最新のブリーフを1件取得する。通信失敗・未認証・空・summary なしは nil。
    /// buyer_daily_briefs は (user_id, brief_date) 単位のため、自分の uid で必ず絞り込む
    /// （バックエンドは BUYER_PROFILE_USER_ID = 同じ Firebase uid で書き込む規約）。
    static func fetchLatest(userId: String? = nil) async -> DailyBrief? {
        guard let uid = userId ?? Auth.auth().currentUser?.uid, !uid.isEmpty else {
            return nil
        }
        do {
            let (data, _) = try await SupabaseClient.shared.select(
                from: "buyer_daily_briefs",
                columns: "brief_date,summary_text,market_insights",
                filters: [("user_id", "eq.\(uid)")],
                order: "brief_date.desc",
                range: 0...0
            )
            return parseLatest(from: data)
        } catch {
            logger.info("デイリーブリーフ取得失敗（ローカル合成にフォールバック）: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// JST の今日を表すキー（"yyyy-MM-dd"）。`.task(id:)` での日跨ぎ再フェッチに使う。
    static func todayKey(now: Date = Date()) -> String {
        dateFormatter.string(from: now)
    }

    /// PostgREST レスポンス（行配列）から先頭ブリーフを取り出す。
    static func parseLatest(from data: Data) -> DailyBrief? {
        guard let rows = try? JSONDecoder().decode([Row].self, from: data),
              let row = rows.first,
              let text = row.summary_text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return DailyBrief(
            briefDate: row.brief_date,
            summaryText: text,
            marketInsights: row.market_insights
        )
    }

    /// ブリーフが「今日（JST）」のものか。
    /// 古いブリーフを朝刊ヘッダーに出すと誤情報になるため、当日分のみ採用する。
    static func isFresh(briefDate: String, now: Date = Date()) -> Bool {
        guard let date = Self.dateFormatter.date(from: briefDate) else { return false }
        return Self.jstCalendar.isDate(date, inSameDayAs: now)
    }

    // MARK: - Private

    private struct Row: Decodable {
        let brief_date: String
        let summary_text: String?
        let market_insights: String?
    }

    private static let jstCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return cal
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
