//
//  ContentView.swift
//  RealEstateApp
//
//  HIG: TabView で主要オブジェクト（物件・地図・お気に入り・成約・設定）を切り替え。
//  物件タブは中古/新築をセグメントピッカーで切替。成約タブは一覧/地図を切替。
//  iOS 26 ではタブバーに Liquid Glass が適用される。
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ListingStore.self) private var store
    @Environment(TransactionStore.self) private var transactionStore
    @Environment(SaveErrorHandler.self) private var saveErrorHandler
    private let networkMonitor = NetworkMonitor.shared
    /// 通知タップ時のディープリンク用。コメント通知で渡される listingIdentityKey に該当する物件を探す。
    /// identityKey は computed プロパティ（name/layout/area 等の組み合わせ）のため、FetchDescriptor の
    /// predicate では検索できず、全件インメモリで first(where:) する必要がある。将来的に identityKey を
    /// ストアド属性にすれば predicate による targeted fetch で最適化可能。
    @Query private var allListings: [Listing]
    @SceneStorage("selectedTab") private var selectedTab = 0
    /// 通知タップで詳細表示する物件
    @State private var notificationListing: Listing?
    /// フォアグラウンド復帰時の自動更新を抑制する最小間隔（秒）
    private let autoRefreshInterval: TimeInterval = 15 * 60  // 15分

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("概況", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(0)
                .accessibilityLabel("マーケット概況")
            PropertyListingTabView()
                .tabItem { Label("物件", systemImage: "building.2") }
                .tag(1)
                .accessibilityLabel("物件一覧")
            MapTabView()
                .tabItem { Label("地図", systemImage: "map") }
                .tag(2)
                .accessibilityLabel("地図で探す")
            ListingListView(favoritesOnly: true)
                .tabItem { Label("お気に入り", systemImage: "heart") }
                .tag(3)
                .accessibilityLabel("お気に入り物件")
            TransactionTabView()
                .tabItem { Label("成約", systemImage: "chart.bar.doc.horizontal") }
                .tag(4)
                .accessibilityLabel("成約実績")
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(5)
                .accessibilityLabel("アプリ設定")
        }
        .tint(.accentColor)
        .onChange(of: selectedTab) { _, _ in
            // タブ切替時にキーボードを閉じる（検索バーのフォーカス残留を防止）
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .overlay(alignment: .top) {
            if !networkMonitor.isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                    Text("オフラインです — データの更新にはインターネット接続が必要です")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.orange)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
            }
        }
        .task {
            // F3: 初回起動時 or SwiftData が空なら自動更新
            // lastFetchedAt は UserDefaults に保存されるため、スキーマ変更で SwiftData が
            // リセットされても nil にならない。件数チェックで空状態を確実に検出する。
            store.requestNotificationPermission()
            if store.lastFetchedAt == nil || allListings.isEmpty {
                await store.refresh(modelContext: modelContext)
            }
            // 成約実績: 初回 or SwiftData が空なら自動取得
            // スキーマバージョン変更で SwiftData がリセットされても lastFetchedAt は
            // UserDefaults に残るため、件数チェックで空状態を検出する（Listing と同様）。
            let txDescriptor = FetchDescriptor<TransactionRecord>()
            let txCount = (try? modelContext.fetchCount(txDescriptor)) ?? 0
            if transactionStore.lastFetchedAt == nil || txCount == 0 {
                await transactionStore.refresh(modelContext: modelContext)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // アプリ復帰 = ユーザーが新着を確認できる状態
                // 累積カウント・バッジ・デリバリー済み通知をクリアする。
                // この後の refresh で新着があれば改めてカウント・通知が設定される。
                NotificationScheduleService.shared.resetAccumulatedCount()

                // F4: フォアグラウンド復帰時に一定間隔経過していたら自動更新
                let elapsed = -(store.lastFetchedAt ?? .distantPast).timeIntervalSinceNow
                if elapsed >= autoRefreshInterval {
                    Task {
                        await store.refresh(modelContext: modelContext)
                    }
                }
                // 成約実績も自動更新（1時間間隔）
                let txElapsed = -(transactionStore.lastFetchedAt ?? .distantPast).timeIntervalSinceNow
                if txElapsed >= 60 * 60 {
                    Task {
                        await transactionStore.refresh(modelContext: modelContext)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapPushNotification)) { notification in
            if let tab = notification.userInfo?["tab"] as? Int {
                selectedTab = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapCommentNotification)) { notification in
            if let key = notification.userInfo?["listingIdentityKey"] as? String,
               let listing = allListings.first(where: { $0.identityKey == key }) {
                notificationListing = listing
            }
        }
        .sheet(item: $notificationListing) { listing in
            ListingDetailView(listing: listing)
        }
        .alert("保存エラー", isPresented: Binding(
            get: { saveErrorHandler.showSaveError },
            set: { saveErrorHandler.showSaveError = $0 }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveErrorHandler.lastSaveError ?? "データの保存に失敗しました")
        }
    }
}

#Preview {
    ContentView()
        .environment(ListingStore.shared)
        .environment(TransactionStore.shared)
        .modelContainer(for: [Listing.self, TransactionRecord.self], inMemory: true)
}
