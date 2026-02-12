//
//  RealEstateAppApp.swift
//  RealEstateApp
//
//  物件情報一覧・詳細・プッシュ通知（新規物件）の iOS アプリ
//

import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseMessaging
import GoogleSignIn

@main
struct RealEstateAppApp: App {
    // FCM 用 AppDelegate
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Listing.self])
        // ディスクへの永続化を試みる
        let diskConfig = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [diskConfig])
        } catch {
            // ディスク失敗時はインメモリにフォールバック（データは永続化されない）
            print("[RealEstateApp] 警告: ModelContainer のディスク作成に失敗、インメモリにフォールバック: \(error.localizedDescription)")
            let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [memoryConfig])
            } catch {
                // インメモリ作成も失敗 = システムレベルの異常（メモリ不足等）
                // SwiftData 必須アプリのため回復不可; Apple テンプレート準拠
                fatalError("[RealEstateApp] ModelContainer の作成に完全に失敗: \(error.localizedDescription)")
            }
        }
    }()

    init() {
        // Firebase 初期化（GoogleService-Info.plist がバンドルに必要）
        FirebaseApp.configure()

        // BGAppRefreshTask 用に共有 ModelContainer を設定してからハンドラ登録
        BackgroundRefreshManager.shared.configure(modelContainer: sharedModelContainer)
        BackgroundRefreshManager.shared.registerTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView(sharedModelContainer: sharedModelContainer)
                .environment(ListingStore.shared)
                .environment(FirebaseSyncService.shared)
                .environment(AuthService.shared)
                .environment(SaveErrorHandler.shared)
                .environment(PhotoSyncService.shared)
                .preferredColorScheme(.light) // ライトモード固定
                .onOpenURL { url in
                    // Google Sign-In のコールバック URL を処理
                    _ = AuthService.shared.handle(url)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - Root View（認証状態に応じて画面を切り替え）

private struct RootView: View {
    @Environment(AuthService.self) private var authService
    @Environment(FirebaseSyncService.self) private var syncService
    let sharedModelContainer: ModelContainer

    /// ウォークスルー表示フラグ
    @State private var showWalkthrough = false

    var body: some View {
        Group {
            if authService.isLoading {
                // Firebase Auth の初期化待ち
                ProgressView()
            } else if authService.isAuthorized {
                // 認証済み + アクセス許可 → メイン画面
                ContentView()
                    .task {
                        // Firestore からアノテーションを取得
                        let context = sharedModelContainer.mainContext
                        await syncService.pullAnnotations(modelContext: context)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                        BackgroundRefreshManager.shared.scheduleNextRefresh()
                    }
                    .onAppear {
                        // 初回ログイン時にウォークスルーを表示
                        if !UserDefaults.standard.walkthroughCompleted {
                            showWalkthrough = true
                        }
                    }
                    .fullScreenCover(isPresented: $showWalkthrough) {
                        WalkthroughView {
                            showWalkthrough = false
                        }
                    }
            } else {
                // 未ログイン → ログイン画面
                LoginView()
            }
        }
    }
}
