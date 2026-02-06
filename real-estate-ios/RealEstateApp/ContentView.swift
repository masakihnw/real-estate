//
//  ContentView.swift
//  RealEstateApp
//
//  HIG: TabView で主要オブジェクト（物件一覧）と設定を切り替え。iOS 26 ではタブバーに Liquid Glass が適用される。
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ListingStore.self) private var store
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ListingListView()
                .tabItem { Label("物件", systemImage: "building.2") }
                .tag(0)
            ListingListView(favoritesOnly: true)
                .tabItem { Label("お気に入り", systemImage: "heart.fill") }
                .tag(1)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(2)
        }
        .tint(.accentColor)
        .onAppear {
            store.requestNotificationPermission()
        }
    }
}

#Preview {
    ContentView()
        .environment(ListingStore.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
