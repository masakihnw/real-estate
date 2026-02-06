//
//  RealEstateAppApp.swift
//  RealEstateApp
//
//  物件情報一覧・詳細・プッシュ通知（新規物件）の iOS アプリ
//

import SwiftUI
import SwiftData
import FirebaseCore

@main
struct RealEstateAppApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Listing.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [config])
    }()

    init() {
        // Firebase 初期化（GoogleService-Info.plist がバンドルに必要）
        FirebaseApp.configure()

        // BGAppRefreshTask のハンドラ登録
        BackgroundRefreshManager.shared.registerTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(ListingStore.shared)
                .environment(FirebaseSyncService.shared)
                .task {
                    // アプリ起動時に匿名認証 → Firestore からアノテーションを取得
                    await FirebaseSyncService.shared.ensureSignedIn()
                    let context = sharedModelContainer.mainContext
                    await FirebaseSyncService.shared.pullAnnotations(modelContext: context)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    BackgroundRefreshManager.shared.scheduleNextRefresh()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
