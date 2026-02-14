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
    @State private var selectedRecord: TransactionRecord?
    @State private var position: MapCameraPosition = .automatic

    /// 建物グループごとに集約したアノテーション
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
            return BuildingGroupAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                ward: first.ward,
                district: first.district,
                builtYear: first.builtYear,
                transactionCount: records.count,
                priceMin: prices.min() ?? 0,
                priceMax: prices.max() ?? 0,
                records: records
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $position) {
                ForEach(groupAnnotations) { annotation in
                    Annotation(annotation.title, coordinate: annotation.coordinate) {
                        Button {
                            selectedRecord = annotation.records.first
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.purple)
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
        .sheet(item: $selectedRecord) { record in
            TransactionDetailView(record: record)
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

    var title: String {
        "\(ward)\(district) \(builtYear)年築"
    }
}
