//
//  RealEstateAppApp.swift
//  RealEstateApp
//
//  物件情報一覧・詳細・プッシュ通知（新規物件）の iOS アプリ
//

import SwiftUI
import SwiftData
import FirebaseCore
import FirebaseCrashlytics
import FirebaseMessaging
import GoogleSignIn
import CoreSpotlight
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "App")

@main
struct RealEstateAppApp: App {
    // FCM 用 AppDelegate
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - スキーマバージョン管理
    // Listing モデルのストアドプロパティを追加・削除・型変更した場合はインクリメントする。
    // 旧バージョンの DB は自動削除され、サーバーからデータを再取得する。
    // VersionedSchema を使わない簡易マイグレーション方式。
    private static let currentSchemaVersion = 17  // v17: isRelisted 追加、バッジ定義変更
    private static let schemaVersionKey = "realestate.schemaVersion"

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Listing.self, TransactionRecord.self])

        // スキーマバージョンが古い場合、既存の DB ファイルを削除して再作成する。
        // SwiftData の自動軽量マイグレーションは Optional プロパティ追加には対応するが、
        // 大量プロパティ (50+) の大きなモデルに繰り返し変更を加えると
        // Objective-C レベルの例外（NSException）でクラッシュすることがあるため、
        // 明示的にバージョンを管理してクリーンスタートを保証する。
        let savedVersion = UserDefaults.standard.integer(forKey: Self.schemaVersionKey)
        if savedVersion < Self.currentSchemaVersion {
            if savedVersion > 0 {
                let diskConfig = ModelConfiguration(isStoredInMemoryOnly: false)
                if let oldContainer = Self.createContainerSafely(for: schema, configurations: [diskConfig]) {
                    let ctx = ModelContext(oldContainer)
                    UserAnnotationStore.backup(from: ctx)
                }
            }
            Self.deleteSwiftDataStore()
            DiskImageCache.shared.clearAll()
            UserDefaults.standard.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
        }

        // ディスクへの永続化を試みる
        let diskConfig = ModelConfiguration(isStoredInMemoryOnly: false)
        if let container = Self.createContainerSafely(for: schema, configurations: [diskConfig]) {
            return container
        }

        // NSException またはエラー — DB を削除してリトライ
        logger.warning("ModelContainer 作成失敗、DB を削除してリトライします")
        Self.deleteSwiftDataStore()
        if let container = Self.createContainerSafely(for: schema, configurations: [diskConfig]) {
            return container
        }

        // ディスクが使えない — インメモリにフォールバック
        logger.warning("リトライも失敗、インメモリにフォールバック")
        let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        if let container = Self.createContainerSafely(for: schema, configurations: [memoryConfig]) {
            return container
        }

        fatalError("""
            [RealEstateApp] データベースの初期化に失敗しました。
            アプリを再インストールするか、ストレージの空き容量を確認してください。
            """)
    }()

    /// NSException を含むすべての例外を安全に捕捉して ModelContainer を生成する。
    private static func createContainerSafely(
        for schema: Schema,
        configurations: [ModelConfiguration]
    ) -> ModelContainer? {
        var container: ModelContainer?
        do {
            try ObjCExceptionCatcher.perform {
                do {
                    container = try ModelContainer(for: schema, configurations: configurations)
                } catch {
                    logger.error("ModelContainer Swift エラー: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("ModelContainer NSException: \(error.localizedDescription)")
            Crashlytics.crashlytics().record(error: error)
        }
        return container
    }

    /// SwiftData のデフォルトストアファイルを削除する。
    /// アノテーション同期キーも合わせてクリアし、次回起動で全件再取得を保証する。
    private static func deleteSwiftDataStore() {
        let base = URL.applicationSupportDirectory
            .appending(path: "default.store")
        let suffixes = ["", "-wal", "-shm"]
        for suffix in suffixes {
            let fileURL = URL(filePath: base.path() + suffix)
            try? FileManager.default.removeItem(at: fileURL)
        }
        UserDefaults.standard.removeObject(forKey: "supabase.annotations.lastSync")
        UserDefaults.standard.removeObject(forKey: "supabase.annotations.didPushLocal")
        print("[RealEstateApp] SwiftData ストアを削除しました（アノテーション同期キーもクリア）")
    }

    init() {
        FirebaseApp.configure()
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)

        BackgroundRefreshManager.shared.configure(modelContainer: sharedModelContainer)
        BackgroundRefreshManager.shared.registerTask()
    }

    private let filterTemplateStore = FilterTemplateStore()

    var body: some Scene {
        WindowGroup {
            RootView(sharedModelContainer: sharedModelContainer)
                .environment(ListingStore.shared)
                .environment(TransactionStore.shared)
                .environment(FirebaseSyncService.shared)
                .environment(AuthService.shared)
                .environment(SaveErrorHandler.shared)
                .environment(PhotoSyncService.shared)
                .environment(filterTemplateStore)
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
    /// Spotlight 検索から開く物件（アプリ起動時に受け取る）
    @State private var spotlightListing: Listing?

    var body: some View {
        Group {
            if authService.isLoading {
                // Firebase Auth の初期化待ち
                ProgressView()
            } else if authService.isAuthorized {
                // 認証済み + アクセス許可 → メイン画面
                ContentView()
                    .task {
                        let context = sharedModelContainer.mainContext
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { await syncService.pullAnnotations(modelContext: context) }
                            group.addTask { await BuyerProfileSyncService.shared.syncOnLaunch() }
                            group.addTask {
                                try? await Task.sleep(for: .seconds(15))
                                logger.warning("起動時同期がタイムアウト（15秒）")
                            }
                            // 最初の2つが完了するか、タイムアウトしたら次へ
                            var completed = 0
                            for await _ in group {
                                completed += 1
                                if completed >= 2 { group.cancelAll(); break }
                            }
                        }
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
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                let context = ModelContext(sharedModelContainer)
                let descriptor = FetchDescriptor<Listing>(predicate: #Predicate<Listing> { $0.url == identifier })
                if let results = try? context.fetch(descriptor), let listing = results.first {
                    spotlightListing = listing
                }
            }
        }
        .fullScreenCover(item: $spotlightListing) { listing in
            ListingDetailView(listing: listing)
        }
    }
}
