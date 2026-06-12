import Foundation

/// 開発者モード解錠のタップカウンタ（設定 > バージョン行を連続タップ）。
///
/// - 規定回数（デフォルト7回）の連続タップで解錠。
/// - タップ間隔が `timeout` を超えるとカウントをリセット（誤発火防止）。
/// - 時刻は注入可能（テストで決定的に検証するため）。
struct DeveloperModeUnlock {
    let tapsRequired: Int
    let timeout: TimeInterval

    private(set) var count: Int = 0
    private(set) var lastTapAt: Date?

    init(tapsRequired: Int = 7, timeout: TimeInterval = 2.0) {
        self.tapsRequired = tapsRequired
        self.timeout = timeout
    }

    /// タップを1回登録する。
    /// - Parameter now: 現在時刻（テスト用に注入可能）
    /// - Returns: このタップで解錠条件を満たしたら true
    mutating func register(now: Date = Date()) -> Bool {
        if let last = lastTapAt, now.timeIntervalSince(last) > timeout {
            count = 0
        }
        count += 1
        lastTapAt = now
        if count >= tapsRequired {
            count = 0
            lastTapAt = nil
            return true
        }
        return false
    }

    /// 解錠までの残りタップ数。
    var remainingTaps: Int {
        max(0, tapsRequired - count)
    }
}
