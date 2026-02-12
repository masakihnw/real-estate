//
//  NotificationScheduleService.swift
//  RealEstateApp
//
//  ローカル通知スケジュール管理。
//  ユーザーが設定した時刻にのみ通知を送信し、
//  前回の通知からのトータル新着件数を表示する。
//

import Foundation
import UserNotifications

@Observable
final class NotificationScheduleService {
    static let shared = NotificationScheduleService()

    // MARK: - 通知カテゴリID
    private static let categoryID = "NEW_LISTINGS_SCHEDULED"

    // MARK: - UserDefaults Keys
    private let defaults = UserDefaults.standard
    private let presetKey = "notification.schedule.preset"
    private let customTimesKey = "notification.schedule.customTimes"
    private let accumulatedCountKey = "notification.accumulatedNewCount"
    private let commentNotifKey = "notification.comment.enabled"

    // MARK: - 定義

    private let notifCountKey = "notification.schedule.count"

    /// 通知スケジュールの1エントリ
    struct ScheduleTime: Codable, Identifiable, Equatable {
        var id: Int { hour * 60 + minute }
        var hour: Int
        var minute: Int

        var date: Date {
            let cal = Calendar.current
            return cal.date(from: DateComponents(hour: hour, minute: minute))
                ?? cal.date(from: DateComponents(hour: 12, minute: 0))
                ?? Date()
        }

        var displayString: String {
            String(format: "%d:%02d", hour, minute)
        }
    }

    // MARK: - Published Properties

    /// 通知回数（0 = OFF、1〜6 = 1日N回）
    var notificationCount: Int {
        get { defaults.integer(forKey: notifCountKey) }
        set {
            let clamped = max(0, min(6, newValue))
            defaults.set(clamped, forKey: notifCountKey)
            adjustScheduleTimes(to: clamped)
            // UI スレッドをブロックしないよう非同期で再スケジュール
            Task.detached(priority: .utility) { [self] in
                rescheduleNotifications()
            }
        }
    }

    /// 後方互換: preset プロパティ（0=off, それ以外=on として扱う）
    enum Preset: Int { case off = 0 }
    var preset: Preset { notificationCount == 0 ? .off : Preset(rawValue: notificationCount) ?? .off }

    /// 回数変更時にスケジュール時刻を調整
    private func adjustScheduleTimes(to count: Int) {
        var current = scheduleTimes
        if count == 0 {
            // OFF: 時刻はそのまま保持（次に ON にした時に復帰）
            return
        }
        if current.count < count {
            // 増やす: デフォルト時刻を追加
            let defaultHours = [8, 12, 17, 7, 10, 20]
            while current.count < count {
                let idx = current.count
                let h = idx < defaultHours.count ? defaultHours[idx] : 8
                current.append(ScheduleTime(hour: h, minute: 0))
            }
        } else if current.count > count {
            // 減らす: 末尾を削除
            current = Array(current.prefix(count))
        }
        // scheduleTimes setter は rescheduleNotifications を呼ぶので直接保存
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: customTimesKey)
        }
    }

    /// スケジュール時刻（カスタマイズ可能）
    var scheduleTimes: [ScheduleTime] {
        get {
            guard let data = defaults.data(forKey: customTimesKey),
                  let times = try? JSONDecoder().decode([ScheduleTime].self, from: data) else {
                // デフォルト: 回数に応じた時刻
                let count = notificationCount
                let defaultHours = [8, 12, 17, 7, 10, 20]
                return (0..<count).map { ScheduleTime(hour: defaultHours[$0 % defaultHours.count], minute: 0) }
            }
            return times
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: customTimesKey)
            }
            Task.detached(priority: .utility) { [self] in
                rescheduleNotifications()
            }
        }
    }

    /// 前回の通知からの累積新着件数
    var accumulatedNewCount: Int {
        get { defaults.integer(forKey: accumulatedCountKey) }
        set { defaults.set(newValue, forKey: accumulatedCountKey) }
    }

    /// コメント通知の ON/OFF（他のユーザーがコメントした時に即時通知）
    var isCommentNotificationEnabled: Bool {
        get { defaults.object(forKey: commentNotifKey) == nil ? true : defaults.bool(forKey: commentNotifKey) }
        set { defaults.set(newValue, forKey: commentNotifKey) }
    }

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// 他のユーザーからのコメントを即時通知する。
    /// - Parameters:
    ///   - authorName: コメント投稿者名
    ///   - text: コメント本文
    ///   - listingName: 物件名
    ///   - listingIdentityKey: 物件の identityKey（タップ時の遷移用）
    func notifyNewComment(authorName: String, text: String, listingName: String, listingIdentityKey: String) {
        guard isCommentNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(authorName) がコメント"
        content.subtitle = listingName
        content.body = text
        content.sound = .default
        content.userInfo = [
            "type": "comment",
            "listingIdentityKey": listingIdentityKey
        ]

        let request = UNNotificationRequest(
            identifier: "comment-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// 他のユーザーからの内見写真追加を即時通知する。
    /// - Parameters:
    ///   - authorName: 写真投稿者名
    ///   - listingName: 物件名
    ///   - listingIdentityKey: 物件の identityKey（タップ時の遷移用）
    func notifyNewPhoto(authorName: String, listingName: String, listingIdentityKey: String) {
        guard isCommentNotificationEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(authorName) が写真を追加"
        content.subtitle = listingName
        content.body = "新しい内見写真が追加されました"
        content.sound = .default
        content.userInfo = [
            "type": "photo",
            "listingIdentityKey": listingIdentityKey
        ]

        let request = UNNotificationRequest(
            identifier: "photo-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// データ更新で新着が見つかった時に呼ぶ。カウントを累積し、通知を再スケジュールする。
    func accumulateAndReschedule(newCount: Int) {
        guard newCount > 0 else { return }
        accumulatedNewCount += newCount
        rescheduleNotifications()
    }

    /// 通知が表示/タップされた時に呼ぶ。カウントをリセットする。
    func resetAccumulatedCount() {
        accumulatedNewCount = 0
        // 次の通知はカウントが0なので不要 → 一旦全部消す
        cancelAllScheduledNotifications()
    }

    /// 全スケジュール済み通知をキャンセル
    func cancelAllScheduledNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: scheduleTimes.enumerated().map { "scheduled-listing-\($0.offset)" }
        )
    }

    /// スケジュール時刻を更新して再登録
    func updateTime(at index: Int, hour: Int, minute: Int) {
        var times = scheduleTimes
        guard index < times.count else { return }
        times[index] = ScheduleTime(hour: hour, minute: minute)
        scheduleTimes = times
    }

    // MARK: - Private

    /// 全スケジュールをキャンセルし、累積カウント > 0 なら再登録
    private func rescheduleNotifications() {
        let center = UNUserNotificationCenter.current()

        // 既存をキャンセル（最大10個分のIDをカバー）
        let ids = (0..<10).map { "scheduled-listing-\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)

        guard notificationCount > 0, accumulatedNewCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "新着物件"
        content.body = "前回の通知から \(accumulatedNewCount)件 の新規物件が追加されました。"
        content.sound = .default
        content.badge = NSNumber(value: accumulatedNewCount)
        content.categoryIdentifier = Self.categoryID

        for (i, time) in scheduleTimes.enumerated() {
            var dateComponents = DateComponents()
            dateComponents.hour = time.hour
            dateComponents.minute = time.minute

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(
                identifier: "scheduled-listing-\(i)",
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error {
                    print("[NotifSchedule] 通知スケジュール失敗 (\(time.displayString)): \(error.localizedDescription)")
                }
            }
        }
    }
}
