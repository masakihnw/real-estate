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

                // 統計サマリー
                transactionSummary

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

    // MARK: - 統計サマリー

    private var transactionSummary: some View {
        let records = filteredRecords
        let prices = records.compactMap(\.priceMan)
        let avgPrice = prices.isEmpty ? 0 : prices.reduce(0, +) / prices.count
        let medianPrice = prices.isEmpty ? 0 : prices.sorted()[prices.count / 2]
        let areas = records.compactMap(\.areaM2)
        let avgArea = areas.isEmpty ? 0 : areas.reduce(0.0, +) / Double(areas.count)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                miniStat("件数", "\(records.count)件")
                if !prices.isEmpty {
                    miniStat("平均価格", Listing.formatPriceCompact(avgPrice))
                    miniStat("中央値", Listing.formatPriceCompact(medianPrice))
                }
                if !areas.isEmpty {
                    miniStat("平均面積", String(format: "%.0fm²", avgArea))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
    }
}
