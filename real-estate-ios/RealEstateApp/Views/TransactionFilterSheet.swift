//
//  TransactionFilterSheet.swift
//  RealEstateApp
//
//  成約実績のフィルタ条件を設定するシート。
//

import SwiftUI
import SwiftData

struct TransactionFilterSheet: View {
    @Bindable var filterStore: TransactionFilterStore
    @Query private var allRecords: [TransactionRecord]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // 価格帯
                Section("価格帯（万円）") {
                    HStack {
                        TextField("下限", value: $filterStore.filter.priceMin, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Text("〜")
                        TextField("上限", value: $filterStore.filter.priceMax, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // 面積
                Section("面積") {
                    HStack {
                        TextField("㎡以上", value: $filterStore.filter.areaMin, format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                        Text("㎡以上")
                    }
                }

                // 徒歩
                Section("推定徒歩（分以内）") {
                    HStack {
                        TextField("分以内", value: $filterStore.filter.walkMax, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Text("分以内")
                    }
                }

                // 間取り
                let layouts = TransactionFilter.availableLayouts(from: allRecords)
                if !layouts.isEmpty {
                    Section("間取り") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                            ForEach(layouts, id: \.self) { layout in
                                let isSelected = filterStore.filter.layouts.contains(layout)
                                Button {
                                    if isSelected {
                                        filterStore.filter.layouts.remove(layout)
                                    } else {
                                        filterStore.filter.layouts.insert(layout)
                                    }
                                } label: {
                                    Text(layout)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? Color.accentColor : Color(.systemGray5))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // 市区町村
                let wards = TransactionFilter.availableWards(from: allRecords).sorted()
                if !wards.isEmpty {
                    Section("市区町村") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                            ForEach(wards, id: \.self) { ward in
                                let isSelected = filterStore.filter.wards.contains(ward)
                                Button {
                                    if isSelected {
                                        filterStore.filter.wards.remove(ward)
                                    } else {
                                        filterStore.filter.wards.insert(ward)
                                    }
                                } label: {
                                    Text(ward)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? Color.accentColor : Color(.systemGray5))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // 取引時期
                let periods = TransactionFilter.availablePeriods(from: allRecords)
                if !periods.isEmpty {
                    Section("取引時期") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                            ForEach(periods, id: \.self) { period in
                                let isSelected = filterStore.filter.tradePeriods.contains(period)
                                Button {
                                    if isSelected {
                                        filterStore.filter.tradePeriods.remove(period)
                                    } else {
                                        filterStore.filter.tradePeriods.insert(period)
                                    }
                                } label: {
                                    Text(period)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? Color.accentColor : Color(.systemGray5))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationTitle("成約実績フィルタ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("リセット") {
                        filterStore.filter.reset()
                    }
                    .disabled(!filterStore.filter.isActive)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
}
