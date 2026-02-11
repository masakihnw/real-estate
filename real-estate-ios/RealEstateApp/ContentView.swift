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
    @Environment(ListingStore.self) private var store
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ListingListView(propertyTypeFilter: "chuko")
                .tabItem { Label("中古", systemImage: "building.2") }
                .tag(0)
            ListingListView(propertyTypeFilter: "shinchiku")
                .tabItem { Label("新築", systemImage: "building.2.crop.circle") }
                .tag(1)
            MapTabView()
                .tabItem { Label("地図", systemImage: "map") }
                .tag(2)
            ListingListView(favoritesOnly: true)
                .tabItem { Label("お気に入り", systemImage: "heart.fill") }
                .tag(3)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(4)
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
