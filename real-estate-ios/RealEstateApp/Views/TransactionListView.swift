//
//  TransactionListView.swift
//  RealEstateApp
//
//  成約実績の一覧表示。推定建物グループ単位でセクション表示し、
//  各セクション内に個別取引を表示する。
//

import SwiftUI
import SwiftData

struct TransactionListView: View {
    @Query(sort: \TransactionRecord.tradePeriod, order: .reverse) private var allRecords: [TransactionRecord]
    @Bindable var filterStore: TransactionFilterStore
    @Environment(TransactionStore.self) private var store

    @State private var selectedRecord: TransactionRecord?

    private var filteredRecords: [TransactionRecord] {
        filterStore.filter.apply(to: allRecords)
    }

    /// 建物グループ単位でグルーピング
    private var groupedRecords: [(groupId: String, label: String, estimatedName: String?, records: [TransactionRecord])] {
        var groups: [String: [TransactionRecord]] = [:]
        for record in filteredRecords {
            let key = record.buildingGroupId ?? record.txId
            groups[key, default: []].append(record)
        }
        return groups.map { (groupId, records) in
            let sample = records.first!
            let estimatedName = records.compactMap(\.estimatedBuildingName).first
            let label = estimatedName ?? "\(sample.ward)\(sample.district)　\(sample.builtYear)年築"
            return (groupId: groupId, label: label, estimatedName: estimatedName, records: records.sorted { $0.tradePeriod > $1.tradePeriod })
        }
        .sorted { lhs, rhs in
            // 直近の取引があるグループを上に
            let lhsLatest = lhs.records.first?.tradePeriod ?? ""
            let rhsLatest = rhs.records.first?.tradePeriod ?? ""
            if lhsLatest != rhsLatest { return lhsLatest > rhsLatest }
            return lhs.records.count > rhs.records.count
        }
    }

    var body: some View {
        Group {
            if allRecords.isEmpty {
                emptyStateView
            } else if filteredRecords.isEmpty {
                noResultsView
            } else {
                listContent
            }
        }
        .sheet(item: $selectedRecord) { record in
            TransactionDetailView(record: record)
        }
    }

    private var listContent: some View {
        List {
            // サマリーヘッダー
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(filteredRecords.count)件の成約実績")
                            .font(.headline)
                        Text("\(groupedRecords.count)棟の推定建物")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if filterStore.filter.isActive {
                        Button {
                            filterStore.filter.reset()
                        } label: {
                            Label("リセット", systemImage: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // 建物グループごとのセクション
            ForEach(groupedRecords, id: \.groupId) { group in
                Section {
                    // グループヘッダー情報
                    groupHeaderView(group: group)

                    // 個別取引
                    ForEach(group.records, id: \.txId) { record in
                        transactionRow(record)
                            .onTapGesture {
                                selectedRecord = record
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func groupHeaderView(group: (groupId: String, label: String, estimatedName: String?, records: [TransactionRecord])) -> some View {
        let sample = group.records.first!
        let prices = group.records.map(\.priceMan)
        let avgM2 = group.records.map(\.m2Price).reduce(0, +) / max(group.records.count, 1)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "building.2.fill")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.label)
                        .font(.subheadline.bold())
                    // 推定名がある場合は住所+築年も補足表示
                    if group.estimatedName != nil {
                        Text("\(sample.ward)\(sample.district)　\(sample.builtYear)年築")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(group.records.count)件")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(Capsule())
            }
            HStack(spacing: 16) {
                if let station = sample.nearestStation, let walk = sample.estimatedWalkMin {
                    Label("\(station) 徒歩\(walk)分", systemImage: "tram.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Label("\(sample.structure)", systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if let minP = prices.min(), let maxP = prices.max() {
                    if minP == maxP {
                        Text("\(minP.formatted())万円")
                            .font(.caption)
                    } else {
                        Text("\(minP.formatted())〜\(maxP.formatted())万円")
                            .font(.caption)
                    }
                }
                Text("平均 \(String(format: "%.1f", Double(avgM2) / 10000))万円/㎡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func transactionRow(_ record: TransactionRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.formattedPrice)
                    .font(.subheadline.bold())
                HStack(spacing: 8) {
                    Text(record.layout)
                    Text("\(String(format: "%.0f", record.areaM2))㎡")
                    Text(record.formattedM2Price)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Spacer()
            Text(record.displayPeriod)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("成約実績なし", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("成約データがまだ取得されていません。\n設定画面から更新してください。")
        }
    }

    private var noResultsView: some View {
        ContentUnavailableView {
            Label("条件に一致する成約なし", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("フィルタ条件を変更してみてください。")
        } actions: {
            Button("フィルタをリセット") {
                filterStore.filter.reset()
            }
        }
    }
}
