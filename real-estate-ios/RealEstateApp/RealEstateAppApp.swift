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

    // MARK: - スキーマバージョン管理
    // Listing モデルのストアドプロパティを追加・削除・型変更した場合はインクリメントする。
    // 旧バージョンの DB は自動削除され、サーバーからデータを再取得する。
    // VersionedSchema を使わない簡易マイグレーション方式。
    private static let currentSchemaVersion = 5  // v5: ssLookupStatus 追加（住まいサーフィン検索ステータス）
    private static let schemaVersionKey = "realestate.schemaVersion"

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Listing.self])

        // スキーマバージョンが古い場合、既存の DB ファイルを削除して再作成する。
        // SwiftData の自動軽量マイグレーションは Optional プロパティ追加には対応するが、
        // 大量プロパティ (50+) の大きなモデルに繰り返し変更を加えると
        // Objective-C レベルの例外（NSException）でクラッシュすることがあるため、
        // 明示的にバージョンを管理してクリーンスタートを保証する。
        let savedVersion = UserDefaults.standard.integer(forKey: Self.schemaVersionKey)
        if savedVersion < Self.currentSchemaVersion {
            Self.deleteSwiftDataStore()
            UserDefaults.standard.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
        }

        // ディスクへの永続化を試みる
        let diskConfig = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [diskConfig])
        } catch {
            // マイグレーション失敗の可能性 — DB を削除してリトライ
            print("[RealEstateApp] 警告: ModelContainer 作成失敗、DB を削除してリトライします: \(error.localizedDescription)")
            Self.deleteSwiftDataStore()
            do {
                return try ModelContainer(for: schema, configurations: [diskConfig])
            } catch {
                // ディスクが完全に使えない場合はインメモリにフォールバック
                print("[RealEstateApp] 警告: リトライも失敗、インメモリにフォールバック: \(error.localizedDescription)")
                let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                do {
                    return try ModelContainer(for: schema, configurations: [memoryConfig])
                } catch {
                    // インメモリ作成も失敗 = システムレベルの異常（メモリ不足等）
                    fatalError("""
                        [RealEstateApp] データベースの初期化に失敗しました。
                        エラー: \(error.localizedDescription)
                        アプリを再インストールするか、ストレージの空き容量を確認してください。
                        """)
                }
            }
        }
    }()

    /// SwiftData のデフォルトストアファイルを削除する
    private static func deleteSwiftDataStore() {
        let base = URL.applicationSupportDirectory
            .appending(path: "default.store")
        // メインファイル + SQLite WAL/SHM
        let suffixes = ["", "-wal", "-shm"]
        for suffix in suffixes {
            let fileURL = URL(filePath: base.path() + suffix)
            try? FileManager.default.removeItem(at: fileURL)
        }
        print("[RealEstateApp] SwiftData ストアを削除しました")
    }

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
