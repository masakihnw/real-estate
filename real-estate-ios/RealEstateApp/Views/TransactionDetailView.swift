//
//  TransactionDetailView.swift
//  RealEstateApp
//
//  成約実績の詳細表示。個別取引レコードの情報と、
//  同一推定建物グループの他の取引も表示する。
//

import SwiftUI
import SwiftData
import MapKit

struct TransactionDetailView: View {
    let record: TransactionRecord
    @Query private var allRecords: [TransactionRecord]
    @Environment(\.dismiss) private var dismiss

    /// 同一建物グループの取引（自身を含む）
    private var sameGroupRecords: [TransactionRecord] {
        guard let gid = record.buildingGroupId else { return [record] }
        return allRecords
            .filter { $0.buildingGroupId == gid }
            .sorted { $0.tradePeriod > $1.tradePeriod }
    }

    var body: some View {
        NavigationStack {
            List {
                // 地図セクション（座標がある場合）
                if let coord = record.coordinate {
                    Section {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                        ))) {
                            Marker(record.displayAddress, coordinate: coord)
                                .tint(.purple)
                        }
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }

                // 基本情報
                Section("取引情報") {
                    row("成約価格", record.formattedPrice)
                    row("m²単価", record.formattedM2Price)
                    row("面積", "\(String(format: "%.1f", record.areaM2))㎡")
                    row("間取り", record.layout)
                    row("取引時期", record.displayPeriod)
                }

                // 建物情報
                Section("建物情報") {
                    if let name = record.estimatedBuildingName, !name.isEmpty {
                        row("推定物件名", name)
                    }
                    row("所在地", record.displayAddress)
                    row("築年", "\(record.builtYear)年")
                    row("構造", record.structure)
                    if let station = record.nearestStation {
                        row("推定最寄駅", station)
                    }
                    if let walk = record.estimatedWalkMin {
                        row("推定徒歩", "\(walk)分（直線距離推定）")
                    }
                }

                // 同一建物の他の取引
                if sameGroupRecords.count > 1 {
                    Section("同一推定建物の成約実績（\(sameGroupRecords.count)件）") {
                        ForEach(sameGroupRecords, id: \.txId) { tx in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tx.formattedPrice)
                                        .font(.subheadline)
                                        .fontWeight(tx.txId == record.txId ? .bold : .regular)
                                    HStack(spacing: 6) {
                                        Text(tx.layout)
                                        Text("\(String(format: "%.0f", tx.areaM2))㎡")
                                        Text(tx.formattedM2Price)
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                }
                                Spacer()
                                Text(tx.displayPeriod)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if tx.txId == record.txId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.purple)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }

                // 注意書き
                Section {
                    Text("この情報は国土交通省「不動産情報ライブラリ」の成約価格情報に基づきます。データは匿名化されており、建物名の特定はできません。最寄駅・徒歩分は座標からの推定値です。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("成約詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}
