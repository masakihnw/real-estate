//
//  TransactionTabView.swift
//  RealEstateApp
//
//  成約実績タブのルートビュー。
//  上部セグメントピッカーで「一覧」「地図」を切り替える。
//  フィルタは一覧・地図で共有する。
//

import SwiftUI
import SwiftData

struct TransactionTabView: View {
    @Query private var allRecords: [TransactionRecord]
    @Environment(TransactionStore.self) private var store
    @Environment(\.modelContext) private var modelContext

    @State private var viewMode: ViewMode = .list
    @State private var filterStore = TransactionFilterStore()

    enum ViewMode: String, CaseIterable {
        case list = "一覧"
        case map = "地図"
    }

    private var filteredRecords: [TransactionRecord] {
        filterStore.filter.apply(to: allRecords)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // セグメントピッカー
                Picker("表示モード", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                // コンテンツ
                switch viewMode {
                case .list:
                    TransactionListView(filterStore: filterStore)
                case .map:
                    TransactionMapView(records: filteredRecords)
                }
            }
            .navigationTitle("成約実績")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        filterStore.showFilterSheet = true
                    } label: {
                        Image(systemName: filterStore.filter.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if store.isRefreshing {
                        ProgressView()
                    }
                }
            }
            .refreshable {
                await store.refresh(modelContext: modelContext)
            }
            .sheet(isPresented: $filterStore.showFilterSheet) {
                TransactionFilterSheet(filterStore: filterStore)
            }
        }
    }
}
