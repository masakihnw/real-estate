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
    case today, browse, favorites, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:     "今日"
        case .browse:    "さがす"
        case .favorites: "マイリスト"
        case .settings:  "設定"
        }
    }

    var icon: String {
        switch self {
        case .today:     "sun.max"
        case .browse:    "magnifyingglass"
        case .favorites: "heart"
        case .settings:  "gearshape"
        }
    }

    var tabIndex: Int {
        switch self {
        case .today:     0
        case .browse:    1
        case .favorites: 2
        case .settings:  3
        }
    }

    init?(tabIndex: Int) {
        switch tabIndex {
        case 0: self = .today
        case 1: self = .browse
        case 2: self = .favorites
        case 3: self = .settings
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
    // キー名 V2: 旧6タブ構成の保存値（tag 0-5 / dashboard 等の rawValue）を引き継がない
    @SceneStorage("selectedTabV2") private var selectedTab = 0
    @SceneStorage("selectedSidebarV2") private var selectedSidebarRaw = SidebarItem.today.rawValue
    /// 通知タップで詳細表示する物件
    @State private var notificationListing: Listing?
    /// Spotlight 検索から開く物件（URL で受け取り、該当物件を表示）
    @State private var spotlightListing: Listing?
    /// スワイプセッション表示制御
    @State private var showSwipeSession = false
    /// 「あとで」で閉じた場合のセッション内抑制フラグ（フォアグラウンド復帰でリセット）
    @State private var swipeDismissedThisSession = false
    /// スワイプ画面を最後に自動表示した暦日キー（1日1回までに抑制する）。
    /// 手動導線（didRequestSwipeSession）はこの値を見ないため常に開ける。
    @AppStorage("lastSwipeAutoPresentDay") private var lastSwipeAutoPresentDay = ""
    /// フォアグラウンド復帰時の自動更新を抑制する最小間隔（秒）
    private let autoRefreshInterval: TimeInterval = 15 * 60  // 15分

    private var selectedSidebarItem: Binding<SidebarItem?> {
        Binding(
            get: { SidebarItem(rawValue: selectedSidebarRaw) },
            set: { selectedSidebarRaw = ($0 ?? .today).rawValue }
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
            await BuildingPreferenceStore.shared.fetch()
            showSwipeIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                NotificationScheduleService.shared.resetAccumulatedCount()
                swipeDismissedThisSession = false
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
                Task {
                    await BuildingPreferenceStore.shared.fetch()
                    showSwipeIfNeeded()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didTapPushNotification)) { notification in
            if let tab = notification.userInfo?["tab"] as? Int,
               let item = SidebarItem(tabIndex: tab) {
                // 範囲外の tab（旧6タブ構成のペイロード等）は無視する
                selectedTab = item.tabIndex
                selectedSidebarRaw = item.rawValue
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
            Task {
                await BuildingPreferenceStore.shared.fetch()
                showSwipeSession = true
            }
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
        let pending = SwipeSessionViewModel.pendingCount(from: listings)
        let today = SwipeAutoPresentGate.dayKey(Date())
        guard SwipeAutoPresentGate.shouldPresent(
            pendingCount: pending,
            lastPresentedDay: lastSwipeAutoPresentDay,
            today: today
        ) else { return }
        // 自動表示は1日1回まで。表示した時点で当日分を消費する
        // （「あとで」で閉じても当日は自動再表示しない。手動では何度でも開ける）。
        lastSwipeAutoPresentDay = today
        showSwipeSession = true
    }

    // MARK: - compact (iPhone): TabView

    private var compactLayout: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem { Label("今日", systemImage: "sun.max") }
                .tag(0)
                .accessibilityLabel("今日の動き")
            BrowseTabView()
                .tabItem { Label("さがす", systemImage: "magnifyingglass") }
                .tag(1)
                .accessibilityLabel("物件をさがす")
            ListingListView(favoritesOnly: true)
                .tabItem { Label("マイリスト", systemImage: "heart") }
                .tag(2)
                .accessibilityLabel("マイリスト")
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(3)
                .accessibilityLabel("アプリ設定")
        }
        .tint(.accentColor)
        .onAppear {
            // 防御: 範囲外の保存値はホームに戻す（存在しない tag を選択すると空表示になるため）
            if !(0...3).contains(selectedTab) { selectedTab = 0 }
        }
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
            switch SidebarItem(rawValue: selectedSidebarRaw) ?? .today {
            case .today:
                TodayView()
            case .browse:
                BrowseTabView()
            case .favorites:
                ListingListView(favoritesOnly: true)
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
        .environment(FilterTemplateStore())
        .modelContainer(for: [Listing.self, TransactionRecord.self], inMemory: true)
}
