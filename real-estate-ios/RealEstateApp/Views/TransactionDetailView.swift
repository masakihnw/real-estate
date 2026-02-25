//
//  TransactionDetailView.swift
//  RealEstateApp
//
//  成約実績の詳細表示。個別取引レコードの情報と、
//  同一推定建物グループの他の取引も表示する。
//  類似面積・間取り別の m²単価推移チャートも表示。
//

import SwiftUI
import SwiftData
import MapKit
import Charts

struct TransactionDetailView: View {
    let record: TransactionRecord
    @Query private var allRecords: [TransactionRecord]
    @Query private var allListings: [Listing]
    @Environment(\.dismiss) private var dismiss
    @State private var isSameGroupExpanded = false

    /// 同一区の販売中物件（掲載終了を除く、最大5件）
    private var nearbyListings: [Listing] {
        let ward = record.ward
        guard !ward.isEmpty else { return [] }
        return allListings
            .filter { !$0.isDelisted && Listing.extractWardFromAddress($0.address ?? "") == ward }
            .prefix(5)
            .map { $0 }
    }

    /// 同一建物グループの取引（自身を含む）
    private var sameGroupRecords: [TransactionRecord] {
        guard let gid = record.buildingGroupId else { return [record] }
        return allRecords
            .filter { $0.buildingGroupId == gid }
            .sorted { $0.tradePeriod > $1.tradePeriod }
    }

    // MARK: - 類似条件の m²単価推移データ

    /// 間取りカテゴリ（"2LDK" or "3LDK"）に正規化
    private static func layoutCategory(_ layout: String) -> String? {
        if layout.hasPrefix("2") { return "2LDK" }
        if layout.hasPrefix("3") { return "3LDK" }
        return nil
    }

    /// チャート用データポイント
    struct TrendPoint: Identifiable {
        let id = UUID()
        let period: String
        let layoutCategory: String
        let avgM2PriceMan: Double
        let count: Int
    }

    /// 類似面積（±15㎡）の 2LDK/3LDK 取引を四半期×間取りで集計
    private var trendData: [TrendPoint] {
        let areaMin = record.areaM2 - 15
        let areaMax = record.areaM2 + 15

        let similar = allRecords.filter { tx in
            tx.areaM2 >= areaMin && tx.areaM2 <= areaMax
                && Self.layoutCategory(tx.layout) != nil
        }

        var buckets: [String: [Int]] = [:]
        for tx in similar {
            guard let cat = Self.layoutCategory(tx.layout) else { continue }
            let key = "\(tx.tradePeriod)|\(cat)"
            buckets[key, default: []].append(tx.m2Price)
        }

        return buckets.compactMap { key, prices in
            let parts = key.split(separator: "|")
            guard parts.count == 2 else { return nil }
            let avg = Double(prices.reduce(0, +)) / Double(prices.count) / 10000.0
            return TrendPoint(
                period: String(parts[0]),
                layoutCategory: String(parts[1]),
                avgM2PriceMan: avg,
                count: prices.count
            )
        }
        .sorted { $0.period < $1.period }
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

                // m²単価推移チャート
                if trendData.count >= 2 {
                    Section {
                        m2PriceTrendChart
                    } header: {
                        Text("類似条件の m²単価推移")
                    } footer: {
                        Text("面積 \(String(format: "%.0f", record.areaM2))㎡ ± 15㎡ の成約実績を間取り別に集計")
                    }
                }

                // 同一建物の他の取引（折りたたみ式）
                if sameGroupRecords.count > 1 {
                    Section {
                        // ヘッダー行（タップで開閉）
                        HStack {
                            Text("同一推定建物の成約実績")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(sameGroupRecords.count)件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: isSameGroupExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isSameGroupExpanded.toggle()
                            }
                        }

                        if isSameGroupExpanded {
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
                }

                // このエリアの販売中物件
                if !nearbyListings.isEmpty {
                    Section("このエリアの販売中物件") {
                        ForEach(nearbyListings, id: \.url) { listing in
                            NavigationLink {
                                ListingDetailView(listing: listing)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(listing.name)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        HStack(spacing: 8) {
                                            Text(listing.priceDisplay)
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                            Text(listing.areaDisplay)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
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

    // MARK: - m²単価推移チャート

    private var m2PriceTrendChart: some View {
        let currentCategory = Self.layoutCategory(record.layout)

        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(trendData) { point in
                    LineMark(
                        x: .value("四半期", point.period),
                        y: .value("m²単価", point.avgM2PriceMan)
                    )
                    .foregroundStyle(by: .value("間取り", point.layoutCategory))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("四半期", point.period),
                        y: .value("m²単価", point.avgM2PriceMan)
                    )
                    .foregroundStyle(by: .value("間取り", point.layoutCategory))
                    .symbolSize(point.period == record.tradePeriod && point.layoutCategory == currentCategory ? 60 : 20)
                }

                // 閲覧中レコードの時期を縦破線でハイライト
                RuleMark(x: .value("現在", record.tradePeriod))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .center) {
                        Text("この取引")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartForegroundStyleScale([
                "2LDK": Color.blue,
                "3LDK": Color.green,
            ])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxisLabel("万円/㎡")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let str = value.as(String.self) {
                            Text(shortPeriodLabel(str))
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 220)
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    /// "2025Q3" → "25Q3" に短縮
    private func shortPeriodLabel(_ period: String) -> String {
        guard period.count >= 6 else { return period }
        let yearStart = period.index(period.startIndex, offsetBy: 2)
        return String(period[yearStart...])
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
