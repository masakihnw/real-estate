//
//  BackgroundRefreshManager.swift
//  RealEstateApp
//
//  BGAppRefreshTask を使い、アプリがバックグラウンドにある間も
//  定期的に物件一覧を取得し、新着があればローカル通知を発火する。
//

import BackgroundTasks
import SwiftData
import Foundation

final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()

    /// BGTaskSchedulerPermittedIdentifiers に登録したタスクID
    static let taskIdentifier = "com.hanawa.realestate.app.refresh"

    /// 次回のバックグラウンド取得までの最小間隔（秒）。
    /// OS が実際に起動するタイミングはユーザーの使用パターンに依存する。
    private let minimumInterval: TimeInterval = 30 * 60  // 30分

    private let modelContainer: ModelContainer

    private init() {
        let schema = Schema([Listing.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("BackgroundRefreshManager: ModelContainer の作成に失敗しました: \(error.localizedDescription)")
        }
    }

    // MARK: - Public

    /// アプリ起動時に1回だけ呼ぶ。BGTaskScheduler にハンドラを登録する。
    /// 注意: `BGTaskScheduler.shared.register` は `application(_:didFinishLaunchingWithOptions:)` 相当の
    ///       タイミング（= App.init）で呼ぶ必要がある。
    func registerTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self, let bgTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(task: bgTask)
        }
    }

    /// 次回のバックグラウンド取得をスケジュールする。
    /// アプリがフォアグラウンドに戻るたび・バックグラウンドタスク完了時に呼ぶ。
    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BGRefresh] スケジュール失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func handleAppRefresh(task: BGAppRefreshTask) {
        // 次回を先にスケジュール（このタスクが完了しても次が予約される）
        scheduleNextRefresh()

        // ModelContext はスレッドセーフではないため、MainActor 上で作成・使用する
        let refreshTask = Task { @MainActor in
            let context = ModelContext(modelContainer)
            await ListingStore.shared.refresh(modelContext: context)
        }

        // タスク期限切れ時のキャンセル処理
        task.expirationHandler = {
            refreshTask.cancel()
        }

        // 完了を通知（キャンセル時やエラー時も正しく処理）
        Task {
            do {
                _ = try await refreshTask.value
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
    }
}
