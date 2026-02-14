//
//  TransactionMapView.swift
//  RealEstateApp
//
//  成約実績データを地図上に表示するビュー。
//  推定建物グループ単位でピンを表示し、タップで吹き出しを表示する。
//

import SwiftUI
import MapKit

struct TransactionMapView: View {
    let records: [TransactionRecord]
    @State private var selectedAnnotation: BuildingGroupAnnotation?
    @State private var position: MapCameraPosition = .automatic

    /// 建物グループごとに集約したアノテーション（1物件 = 1ピン）
    private var groupAnnotations: [BuildingGroupAnnotation] {
        var groups: [String: [TransactionRecord]] = [:]
        for record in records where record.hasCoordinate {
            let key = record.buildingGroupId ?? record.txId
            groups[key, default: []].append(record)
        }

        return groups.compactMap { (_, records) -> BuildingGroupAnnotation? in
            guard let first = records.first,
                  let lat = first.latitude, let lon = first.longitude else { return nil }
            let prices = records.map(\.priceMan)
            // 推定物件名: グループ内のいずれかに名前があれば採用
            let estimatedName = records.compactMap(\.estimatedBuildingName).first
            return BuildingGroupAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                ward: first.ward,
                district: first.district,
                builtYear: first.builtYear,
                transactionCount: records.count,
                priceMin: prices.min() ?? 0,
                priceMax: prices.max() ?? 0,
                records: records,
                estimatedBuildingName: estimatedName
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $position) {
                ForEach(groupAnnotations) { annotation in
                    Annotation(annotation.shortTitle, coordinate: annotation.coordinate) {
                        Button {
                            selectedAnnotation = annotation
                        } label: {
                            VStack(spacing: 2) {
                                ZStack {
                                    Circle()
                                        .fill(annotation.estimatedBuildingName != nil ? Color.purple : Color.purple.opacity(0.7))
                                        .frame(width: annotationSize(for: annotation.transactionCount),
                                               height: annotationSize(for: annotation.transactionCount))
                                    Text("\(annotation.transactionCount)")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white)
                                }
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .including([.publicTransport])))

            // 凡例
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Circle().fill(.purple).frame(width: 8, height: 8)
                    Text("成約実績")
                        .font(.caption2)
                }
                Text("\(groupAnnotations.count)棟 / \(records.filter(\.hasCoordinate).count)件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
        .sheet(item: $selectedAnnotation) { annotation in
            BuildingGroupDetailView(annotation: annotation)
        }
    }

    private func annotationSize(for count: Int) -> CGFloat {
        switch count {
        case 1: return 24
        case 2...3: return 28
        case 4...6: return 32
        default: return 36
        }
    }
}

// MARK: - BuildingGroupAnnotation

struct BuildingGroupAnnotation: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let ward: String
    let district: String
    let builtYear: Int
    let transactionCount: Int
    let priceMin: Int
    let priceMax: Int
    let records: [TransactionRecord]
    let estimatedBuildingName: String?

    /// 地図上のタイトル（推定物件名があればそれを優先）
    var title: String {
        if let name = estimatedBuildingName, !name.isEmpty {
            return name
        }
        return "\(ward)\(district) \(builtYear)年築"
    }

    /// 地図アノテーション用の短いタイトル
    var shortTitle: String {
        if let name = estimatedBuildingName, !name.isEmpty {
            // " / " 区切りの場合は最初の候補のみ
            return name.components(separatedBy: " / ").first ?? name
        }
        return "\(district) \(builtYear)年"
    }

    /// 価格帯の表示文字列
    var priceRangeText: String {
        if priceMin == priceMax {
            return "\(priceMin.formatted())万円"
        }
        return "\(priceMin.formatted())〜\(priceMax.formatted())万円"
    }
}

// MARK: - BuildingGroupDetailView（地図ピンタップ時の詳細シート）

struct BuildingGroupDetailView: View {
    let annotation: BuildingGroupAnnotation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // 地図
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: annotation.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                    ))) {
                        Marker(annotation.title, coordinate: annotation.coordinate)
                            .tint(.purple)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                // 物件情報
                Section("推定物件情報") {
                    if let name = annotation.estimatedBuildingName, !name.isEmpty {
                        row("推定物件名", name)
                    }
                    row("所在地", "\(annotation.ward)\(annotation.district)")
                    row("築年", "\(annotation.builtYear)年")
                    if let station = annotation.records.first?.nearestStation {
                        row("推定最寄駅", station)
                    }
                    if let walk = annotation.records.first?.estimatedWalkMin {
                        row("推定徒歩", "\(walk)分")
                    }
                    row("構造", annotation.records.first?.structure ?? "—")
                }

                // サマリー
                Section("成約実績サマリー（\(annotation.transactionCount)件）") {
                    row("価格帯", annotation.priceRangeText)
                    let avgM2 = annotation.records.map(\.m2Price).reduce(0, +) / max(annotation.records.count, 1)
                    row("平均m²単価", String(format: "%.1f万円/㎡", Double(avgM2) / 10000))
                    let layouts = Set(annotation.records.map(\.layout)).sorted()
                    row("間取り", layouts.joined(separator: ", "))
                }

                // 各成約一覧
                Section("成約履歴") {
                    ForEach(annotation.records.sorted(by: { $0.tradePeriod > $1.tradePeriod }), id: \.txId) { tx in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tx.formattedPrice)
                                    .font(.subheadline.bold())
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
                        }
                    }
                }

                // 注意書き
                Section {
                    Text("この情報は国土交通省「不動産情報ライブラリ」の成約価格情報に基づきます。物件名は既存のスクレイピングデータとのクロスリファレンスによる推定であり、正確性は保証されません。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(annotation.title)
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
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
