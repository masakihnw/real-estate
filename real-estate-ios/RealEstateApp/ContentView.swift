//
//  ContentView.swift
//  RealEstateApp
//
//  HIG: TabView で主要オブジェクト（中古・新築・地図・お気に入り・設定）を切り替え。
//  iOS 26 ではタブバーに Liquid Glass が適用される。
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ListingStore.self) private var store
    @SceneStorage("selectedTab") private var selectedTab = 0
    /// フォアグラウンド復帰時の自動更新を抑制する最小間隔（秒）
    private let autoRefreshInterval: TimeInterval = 15 * 60  // 15分

    var body: some View {
        TabView(selection: $selectedTab) {
            ListingListView(propertyTypeFilter: "chuko")
                .tabItem { Label("中古", image: "tab-chuko") }
                .tag(0)
            ListingListView(propertyTypeFilter: "shinchiku")
                .tabItem { Label("新築", image: "tab-shinchiku") }
                .tag(1)
            MapTabView()
                .tabItem { Label("地図", image: "tab-map") }
                .tag(2)
            ListingListView(favoritesOnly: true)
                .tabItem { Label("お気に入り", image: "tab-favorites") }
                .tag(3)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(4)
        }
        .tint(.accentColor)
        .task {
            // F3: 初回起動時、データが空 or 最終取得が nil なら自動更新
            store.requestNotificationPermission()
            if store.lastFetchedAt == nil {
                await store.refresh(modelContext: modelContext)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // F4: フォアグラウンド復帰時に一定間隔経過していたら自動更新
            if newPhase == .active {
                let elapsed = -(store.lastFetchedAt ?? .distantPast).timeIntervalSinceNow
                if elapsed >= autoRefreshInterval {
                    Task {
                        await store.refresh(modelContext: modelContext)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapPushNotification)) { notification in
            if let tab = notification.userInfo?["tab"] as? Int {
                selectedTab = tab
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(ListingStore.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
