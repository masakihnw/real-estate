//
//  ContentView.swift
//  RealEstateApp
//
//  compact (iPhone): TabView で主要セクションを切り替え。
//  regular (iPad / Mac Catalyst): NavigationSplitView でサイドバー＋詳細の2カラム構成。
//  iOS 26 ではタブバーに Liquid Glass が適用される。
//

import SwiftUI
import SwiftData

// MARK: - サイドバー項目（iPad / Mac）

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard, listings, map, favorites, transactions, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:    "概況"
        case .listings:     "物件"
        case .map:          "地図"
        case .favorites:    "マイリスト"
        case .transactions: "成約"
        case .settings:     "設定"
        }
    }

    var icon: String {
        switch self {
        case .dashboard:    "chart.line.uptrend.xyaxis"
        case .listings:     "building.2"
        case .map:          "map"
        case .favorites:    "list.star"
        case .transactions: "chart.bar.doc.horizontal"
        case .settings:     "gearshape"
        }
    }

    var tabIndex: Int {
        switch self {
        case .dashboard:    0
        case .listings:     1
        case .map:          2
        case .favorites:    3
        case .transactions: 4
        case .settings:     5
        }
    }

    init?(tabIndex: Int) {
        switch tabIndex {
        case 0: self = .dashboard
        case 1: self = .listings
        case 2: self = .map
        case 3: self = .favorites
        case 4: self = .transactions
        case 5: self = .settings
        default: return nil
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ListingStore.self) private var store
    @Environment(TransactionStore.self) private var transactionStore
    @Environment(SaveErrorHandler.self) private var saveErrorHandler
    private let networkMonitor = NetworkMonitor.shared
    @SceneStorage("selectedTab") private var selectedTab = 0
    @SceneStorage("selectedSidebar") private var selectedSidebarRaw = SidebarItem.dashboard.rawValue
    /// 通知タップで詳細表示する物件
    @State private var notificationListing: Listing?
    /// Spotlight 検索から開く物件（URL で受け取り、該当物件を表示）
    @State private var spotlightListing: Listing?
    /// スワイプセッション表示制御
    @State private var showSwipeSession = false
    /// 「あとで」で閉じた場合のセッション内抑制フラグ（フォアグラウンド復帰でリセット）
    @State private var swipeDismissedThisSession = false
    /// フォアグラウンド復帰時の自動更新を抑制する最小間隔（秒）
    private let autoRefreshInterval: TimeInterval = 15 * 60  // 15分

    private var selectedSidebarItem: Binding<SidebarItem?> {
        Binding(
            get: { SidebarItem(rawValue: selectedSidebarRaw) },
            set: { selectedSidebarRaw = ($0 ?? .dashboard).rawValue }
        )
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
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
            store.requestNotificationPermission()
            let listingCount = (try? modelContext.fetchCount(FetchDescriptor<Listing>())) ?? 0
            if store.lastFetchedAt == nil || listingCount == 0 {
                await store.refresh(modelContext: modelContext)
            }
            let txDescriptor = FetchDescriptor<TransactionRecord>()
            let txCount = (try? modelContext.fetchCount(txDescriptor)) ?? 0
            if transactionStore.lastFetchedAt == nil || txCount == 0 {
                await transactionStore.refresh(modelContext: modelContext)
            }
            showSwipeIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                NotificationScheduleService.shared.resetAccumulatedCount()
                swipeDismissedThisSession = false
                // オフライン時はキャッシュ済みデータがある場合は自動更新をスキップ
                guard networkMonitor.isConnected else { return }
                let elapsed = -(store.lastFetchedAt ?? .distantPast).timeIntervalSinceNow
                if elapsed >= autoRefreshInterval {
                    Task {
                        await store.refresh(modelContext: modelContext)
                    }
                }
                let txElapsed = -(transactionStore.lastFetchedAt ?? .distantPast).timeIntervalSinceNow
                if txElapsed >= 60 * 60 {
                    Task {
                        await transactionStore.refresh(modelContext: modelContext)
                    }
                }
                showSwipeIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapPushNotification)) { notification in
            if let tab = notification.userInfo?["tab"] as? Int {
                selectedTab = tab
                if let item = SidebarItem(tabIndex: tab) {
                    selectedSidebarRaw = item.rawValue
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapCommentNotification)) { notification in
            if let key = notification.userInfo?["listingIdentityKey"] as? String {
                let descriptor = FetchDescriptor<Listing>()
                if let all = try? modelContext.fetch(descriptor),
                   let listing = all.first(where: { $0.identityKey == key }) {
                    notificationListing = listing
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didRequestSwipeSession)) { _ in
            showSwipeSession = true
        }
        .fullScreenCover(isPresented: $showSwipeSession) {
            let listings = (try? modelContext.fetch(FetchDescriptor<Listing>())) ?? []
            SwipeSessionView(listings: listings) {
                swipeDismissedThisSession = true
                showSwipeSession = false
            }
        }
        .fullScreenCover(item: $notificationListing) { listing in
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

    // MARK: - Swipe Auto-Presentation

    private func showSwipeIfNeeded() {
        guard !swipeDismissedThisSession,
              !showSwipeSession,
              notificationListing == nil else { return }
        let listings = (try? modelContext.fetch(FetchDescriptor<Listing>())) ?? []
        guard SwipeSessionViewModel.pendingCount(from: listings) > 0 else { return }
        showSwipeSession = true
    }

    // MARK: - compact (iPhone): TabView

    private var compactLayout: some View {
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
                .tabItem { Label("マイリスト", systemImage: "list.star") }
                .tag(3)
                .accessibilityLabel("マイリスト")
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
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    // MARK: - regular (iPad / Mac): NavigationSplitView

    private var regularLayout: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, id: \.self, selection: selectedSidebarItem) { item in
                Label(item.title, systemImage: item.icon)
            }
            .navigationTitle("物件情報")
        } detail: {
            switch SidebarItem(rawValue: selectedSidebarRaw) ?? .dashboard {
            case .dashboard:
                DashboardView()
            case .listings:
                PropertyListingTabView()
            case .map:
                MapTabView()
            case .favorites:
                ListingListView(favoritesOnly: true)
            case .transactions:
                TransactionTabView()
            case .settings:
                SettingsView()
            }
        }
        .tint(.accentColor)
    }
}

#Preview {
    ContentView()
        .environment(ListingStore.shared)
        .environment(TransactionStore.shared)
        .modelContainer(for: [Listing.self, TransactionRecord.self], inMemory: true)
}
