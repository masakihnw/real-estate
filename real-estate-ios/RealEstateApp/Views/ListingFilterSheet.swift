//
//  ListingFilterSheet.swift
//  RealEstateApp
//
//  HIG: フィルタは sheet で提示。各条件を直感的に操作できるようにする。
//

import SwiftUI

struct ListingFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: ListingFilter
    let availableLayouts: [String]
    let stationsByLine: [(line: String, stations: [String])]

    // ローカル編集用（「適用」で反映）
    @State private var editFilter = ListingFilter()

    // 価格の選択肢（万円）
    private let priceOptions = [5000, 6000, 7000, 7500, 8000, 8500, 9000, 9500, 10000, 11000, 12000, 15000]
    // 徒歩の選択肢（分）
    private let walkOptions = [3, 5, 7, 10, 15]
    // 専有面積の選択肢（㎡）
    private let areaOptions: [Double] = [50, 55, 60, 65, 70, 75, 80]

    var body: some View {
        NavigationStack {
            Form {
                priceSection
                layoutSection
                stationSections
                walkSection
                areaSection
                ownershipSection
                resetSection
            }
            .navigationTitle("フィルタ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") {
                        filter = editFilter
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                editFilter = filter
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var priceSection: some View {
        Section("価格（万円）") {
            HStack {
                Picker("下限", selection: $editFilter.priceMin) {
                    Text("指定なし").tag(Int?.none)
                    ForEach(priceOptions, id: \.self) { v in
                        Text("\(v)万〜").tag(Int?.some(v))
                    }
                }
                .pickerStyle(.menu)
                Text("〜")
                Picker("上限", selection: $editFilter.priceMax) {
                    Text("指定なし").tag(Int?.none)
                    ForEach(priceOptions, id: \.self) { v in
                        Text("〜\(v)万").tag(Int?.some(v))
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var layoutSection: some View {
        if !availableLayouts.isEmpty {
            Section("間取り") {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 70))
                ], spacing: 8) {
                    ForEach(availableLayouts, id: \.self) { layout in
                        gridToggleButton(
                            label: layout,
                            isSelected: editFilter.layouts.contains(layout)
                        ) {
                            toggleSet(&editFilter.layouts, value: layout)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var stationSections: some View {
        ForEach(stationsByLine, id: \.line) { group in
            stationLineSection(lineName: group.line, stations: group.stations)
        }
    }

    @ViewBuilder
    private func stationLineSection(lineName: String, stations: [String]) -> some View {
        Section("駅 — \(lineName)") {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 80))
            ], spacing: 8) {
                ForEach(stations, id: \.self) { station in
                    gridToggleButton(
                        label: station,
                        isSelected: editFilter.stations.contains(station)
                    ) {
                        toggleSet(&editFilter.stations, value: station)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var walkSection: some View {
        Section("駅徒歩") {
            Picker("徒歩", selection: $editFilter.walkMax) {
                Text("指定なし").tag(Int?.none)
                ForEach(walkOptions, id: \.self) { v in
                    Text("\(v)分以内").tag(Int?.some(v))
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var areaSection: some View {
        Section("専有面積") {
            Picker("面積", selection: $editFilter.areaMin) {
                Text("指定なし").tag(Double?.none)
                ForEach(areaOptions, id: \.self) { v in
                    Text("\(Int(v))㎡以上").tag(Double?.some(v))
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var ownershipSection: some View {
        Section("権利形態") {
            ownershipRow(.ownership)
            ownershipRow(.leasehold)
        }
    }

    @ViewBuilder
    private func ownershipRow(_ type: OwnershipType) -> some View {
        let selected = editFilter.ownershipTypes.contains(type)
        Button {
            if selected {
                editFilter.ownershipTypes.remove(type)
            } else {
                editFilter.ownershipTypes.insert(type)
            }
        } label: {
            HStack {
                Text(type.rawValue)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button("すべてリセット", role: .destructive) {
                editFilter.reset()
            }
        }
    }

    // MARK: - Helpers

    /// グリッド内のトグルボタン（間取り・駅で共通）
    @ViewBuilder
    private func gridToggleButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(ListingObjectStyle.subtitle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listingGlassBackground()
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.cornerRadius)
                        .stroke(
                            isSelected ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggleSet(_ set: inout Set<String>, value: String) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }
}

#Preview {
    ListingFilterSheet(
        filter: .constant(ListingFilter()),
        availableLayouts: ["2LDK", "3LDK", "2DK", "3DK"],
        stationsByLine: [
            (line: "東京メトロ南北線", stations: ["王子", "赤羽岩淵", "志茂"]),
            (line: "東京メトロ有楽町線", stations: ["豊洲", "辰巳"])
        ]
    )
}
