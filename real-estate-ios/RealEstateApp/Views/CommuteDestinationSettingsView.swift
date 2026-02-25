//
//  CommuteDestinationSettingsView.swift
//  RealEstateApp
//
//  通勤先の追加・削除・デフォルト復元を設定する画面。
//

import CoreLocation
import SwiftUI

struct CommuteDestinationSettingsView: View {
    @State private var destinations: [CommuteDestinationConfig] = CommuteDestinationConfig.load()
    @State private var isAddingNew = false
    @State private var newName = ""
    @State private var newAddress = ""
    @State private var isGeocoding = false

    var body: some View {
        List {
            Section {
                ForEach(destinations) { dest in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dest.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(String(format: "%.6f, %.6f", dest.latitude, dest.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: deleteDestination)
            } header: {
                Text("通勤先")
            } footer: {
                Text("通勤時間の計算に使用されます。最大3箇所まで設定できます。")
            }

            if destinations.count < 3 {
                Section {
                    if isAddingNew {
                        VStack(spacing: 12) {
                            TextField("名前（例: 会社名）", text: $newName)
                            TextField("住所（例: 千代田区一番町4-6）", text: $newAddress)
                            HStack {
                                Button("キャンセル") {
                                    isAddingNew = false
                                    newName = ""
                                    newAddress = ""
                                }
                                Spacer()
                                Button {
                                    geocodeAndAdd()
                                } label: {
                                    if isGeocoding {
                                        ProgressView()
                                    } else {
                                        Text("追加")
                                    }
                                }
                                .disabled(newName.isEmpty || newAddress.isEmpty || isGeocoding)
                            }
                        }
                    } else {
                        Button {
                            isAddingNew = true
                        } label: {
                            Label("通勤先を追加", systemImage: "plus.circle")
                        }
                    }
                }
            }

            Section {
                Button("デフォルトに戻す") {
                    destinations = CommuteDestinationConfig.defaults
                    CommuteDestinationConfig.save(destinations)
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("通勤先設定")
    }

    private func deleteDestination(at offsets: IndexSet) {
        destinations.remove(atOffsets: offsets)
        CommuteDestinationConfig.save(destinations)
    }

    private func geocodeAndAdd() {
        isGeocoding = true
        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(newAddress) { placemarks, _ in
            DispatchQueue.main.async {
                isGeocoding = false
                if let coord = placemarks?.first?.location?.coordinate {
                    let id = newName.lowercased().replacingOccurrences(of: " ", with: "_")
                    let config = CommuteDestinationConfig(
                        id: id + "_\(Int(Date().timeIntervalSince1970))",
                        name: newName,
                        latitude: coord.latitude,
                        longitude: coord.longitude
                    )
                    destinations.append(config)
                    CommuteDestinationConfig.save(destinations)
                    newName = ""
                    newAddress = ""
                    isAddingNew = false
                }
            }
        }
    }
}
