//
//  PushNotificationService.swift
//  RealEstateApp
//
//  Firebase Cloud Messaging (FCM) によるリモートプッシュ通知。
//  トピック "new_listings" を購読し、GitHub Actions からの通知を受信する。
//

import Foundation
import UIKit
import UserNotifications
import FirebaseMessaging

/// プッシュ通知タップ時に画面遷移するための通知名
extension Notification.Name {
    static let didTapPushNotification = Notification.Name("didTapPushNotification")
    /// コメント通知タップ → 該当物件の詳細画面へ遷移
    static let didTapCommentNotification = Notification.Name("didTapCommentNotification")
}

/// AppDelegate — FCM のデバイストークン登録とリモート通知受信を処理
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // FCM delegate
        Messaging.messaging().delegate = self

        // 通知権限リクエスト
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        }

        return true
    }

    // APNs トークンを FCM に渡す
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Push] APNs 登録失敗: \(error.localizedDescription)")
    }
}

// MARK: - MessagingDelegate

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        #if DEBUG
        print("[Push] FCM Token: \(token)")
        #endif

        // トピック "new_listings" を購読
        Messaging.messaging().subscribe(toTopic: "new_listings") { error in
            if let error {
                print("[Push] トピック購読失敗: \(error.localizedDescription)")
            } else {
                print("[Push] トピック 'new_listings' 購読完了")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// フォアグラウンドで受信した通知をバナー表示する
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // スケジュール通知が表示された → カウントリセット
        if notification.request.identifier.hasPrefix("scheduled-listing-") {
            NotificationScheduleService.shared.resetAccumulatedCount()
        }
        completionHandler([.banner, .sound, .badge])
    }

    /// 通知タップ時の処理
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // スケジュール通知がタップされた → カウントリセット
        if response.notification.request.identifier.hasPrefix("scheduled-listing-") {
            NotificationScheduleService.shared.resetAccumulatedCount()
            NotificationCenter.default.post(
                name: .didTapPushNotification,
                object: nil,
                userInfo: ["tab": 0]
            )
        }
        // コメント通知がタップされた → 該当物件の詳細画面へ
        else if userInfo["type"] as? String == "comment",
                let identityKey = userInfo["listingIdentityKey"] as? String {
            NotificationCenter.default.post(
                name: .didTapCommentNotification,
                object: nil,
                userInfo: ["listingIdentityKey": identityKey]
            )
        }
        // その他 → 中古タブに遷移
        else {
            NotificationCenter.default.post(
                name: .didTapPushNotification,
                object: nil,
                userInfo: ["tab": 0]
            )
        }
        completionHandler()
    }
}
