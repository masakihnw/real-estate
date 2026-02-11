//
//  ListingFilterSheet.swift
//  RealEstateApp
//
//  アコーディオン折りたたみ式フィルタ。スライダー + チップ + 区グリッド。
//

import SwiftUI

// MARK: - 区グループ定義

private let wardGroups: [(area: String, wards: [String])] = [
    ("都心エリア", ["千代田区", "中央区", "港区"]),
    ("城東エリア", ["江東区", "墨田区", "台東区", "江戸川区", "葛飾区", "足立区"]),
    ("城南エリア", ["品川区", "大田区", "目黒区"]),
    ("城西エリア", ["渋谷区", "新宿区", "世田谷区"]),
    ("城北エリア", ["文京区", "豊島区", "北区", "板橋区", "練馬区", "荒川区"]),
    ("多摩エリア", ["杉並区", "中野区", "武蔵野市"]),
]

// MARK: - Filter Sheet

struct ListingFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: ListingFilter
    let availableLayouts: [String]
    let availableWards: Set<String>
    let availableStations: [String]
    let filteredCount: Int

    // ローカル編集用（「適用」ではなく下部ボタンで反映）
    @State private var editFilter = ListingFilter()

    // 価格の範囲
    private let priceRange: ClosedRange<Double> = 5000...15000
    private let priceStep: Double = 500
    // 徒歩の範囲
    private let walkRange: ClosedRange<Double> = 1...20
    // 面積の範囲
    private let areaRange: ClosedRange<Double> = 45...100

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 価格帯
                    FilterAccordion(
                        title: "価格帯",
                        summary: priceSummary
                    ) {
                        priceSliderContent
                    }

                    // 間取り
                    if !availableLayouts.isEmpty {
                        FilterAccordion(
                            title: "間取り",
                            summary: layoutSummary
                        ) {
                            layoutChipsContent
                        }
                    }

                    // 駅徒歩
                    FilterAccordion(
                        title: "駅徒歩",
                        summary: walkSummary
                    ) {
                        walkSliderContent
                    }

                    // 広さ
                    FilterAccordion(
                        title: "広さ",
                        summary: areaSummary
                    ) {
                        areaSliderContent
                    }

                    // 駅名
                    FilterAccordion(
                        title: "駅名",
                        summary: stationSummary
                    ) {
                        stationChipsContent
                    }

                    // 権利形態
                    FilterAccordion(
                        title: "権利形態",
                        summary: ownershipSummary
                    ) {
                        ownershipChipsContent
                    }

                    // エリア（区）
                    FilterAccordion(
                        title: "エリア（区）",
                        summary: wardSummary
                    ) {
                        wardGridContent
                    }
                }
                .padding(.horizontal, 16)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    filter = editFilter
                    dismiss()
                } label: {
                    Text(filteredCount > 0 ? "\(filteredCount)件の物件を表示" : "該当する物件がありません")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(.regularMaterial)
            }
            .navigationTitle("フィルタ")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("リセット") {
                        withAnimation { editFilter.reset() }
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .onAppear { editFilter = filter }
        }
    }

    // MARK: - Summaries

    private var priceSummary: String {
        if let min = editFilter.priceMin, let max = editFilter.priceMax {
            return "\(min)万〜\(max)万"
        } else if let min = editFilter.priceMin {
            return "\(min)万〜"
        } else if let max = editFilter.priceMax {
            return "〜\(max)万"
        }
        return "指定なし"
    }

    private var layoutSummary: String {
        editFilter.layouts.isEmpty ? "指定なし" : editFilter.layouts.sorted().joined(separator: ", ")
    }

    private var walkSummary: String {
        guard let max = editFilter.walkMax else { return "指定なし" }
        return "\(max)分以内"
    }

    private var areaSummary: String {
        guard let min = editFilter.areaMin else { return "指定なし" }
        return "\(Int(min))㎡以上"
    }

    private var ownershipSummary: String {
        if editFilter.ownershipTypes.isEmpty { return "指定なし" }
        return editFilter.ownershipTypes.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private var wardSummary: String {
        if editFilter.wards.isEmpty { return "指定なし" }
        let sorted = editFilter.wards.sorted()
        if sorted.count <= 3 { return sorted.joined(separator: ", ") }
        return "\(sorted.prefix(2).joined(separator: ", ")) 他\(sorted.count - 2)区"
    }

    private var stationSummary: String {
        if editFilter.stations.isEmpty { return "指定なし" }
        let sorted = editFilter.stations.sorted()
        if sorted.count <= 3 { return sorted.joined(separator: ", ") }
        return "\(sorted.prefix(2).joined(separator: ", ")) 他\(sorted.count - 2)駅"
    }

    // MARK: - Price Slider

    @ViewBuilder
    private var priceSliderContent: some View {
        VStack(spacing: 6) {
            let minVal = Double(editFilter.priceMin ?? Int(priceRange.lowerBound))
            let maxVal = Double(editFilter.priceMax ?? Int(priceRange.upperBound))
            HStack {
                Text("\(Int(minVal))万")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(maxVal))万")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("下限")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(editFilter.priceMin ?? Int(priceRange.lowerBound)) },
                        set: { editFilter.priceMin = Int($0) == Int(priceRange.lowerBound) ? nil : Int($0) }
                    ),
                    in: priceRange,
                    step: priceStep
                )
                .tint(.accentColor)
            }
            HStack(spacing: 8) {
                Text("上限")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(editFilter.priceMax ?? Int(priceRange.upperBound)) },
                        set: { editFilter.priceMax = Int($0) == Int(priceRange.upperBound) ? nil : Int($0) }
                    ),
                    in: priceRange,
                    step: priceStep
                )
                .tint(.accentColor)
            }
        }
    }

    // MARK: - Layout Chips

    @ViewBuilder
    private var layoutChipsContent: some View {
        FlowLayout(spacing: 6) {
            ForEach(availableLayouts, id: \.self) { layout in
                FilterChip(
                    label: layout,
                    isSelected: editFilter.layouts.contains(layout)
                ) {
                    toggleSet(&editFilter.layouts, value: layout)
                }
            }
        }
    }

    // MARK: - Walk Slider

    @ViewBuilder
    private var walkSliderContent: some View {
        VStack(spacing: 4) {
            let val = Double(editFilter.walkMax ?? Int(walkRange.upperBound))
            HStack {
                Slider(
                    value: Binding(
                        get: { val },
                        set: { editFilter.walkMax = Int($0) == Int(walkRange.upperBound) ? nil : Int($0) }
                    ),
                    in: walkRange,
                    step: 1
                )
                .tint(.accentColor)
                Text(editFilter.walkMax.map { "\($0)分以内" } ?? "指定なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    // MARK: - Area Slider

    @ViewBuilder
    private var areaSliderContent: some View {
        VStack(spacing: 4) {
            let val = editFilter.areaMin ?? areaRange.lowerBound
            HStack {
                Slider(
                    value: Binding(
                        get: { val },
                        set: { editFilter.areaMin = $0 <= areaRange.lowerBound ? nil : $0 }
                    ),
                    in: areaRange,
                    step: 5
                )
                .tint(.accentColor)
                Text(editFilter.areaMin.map { "\(Int($0))㎡以上" } ?? "指定なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    // MARK: - Station Chips

    @ViewBuilder
    private var stationChipsContent: some View {
        if availableStations.isEmpty {
            Text("駅データがありません")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(availableStations, id: \.self) { station in
                    FilterChip(
                        label: station,
                        isSelected: editFilter.stations.contains(station)
                    ) {
                        toggleSet(&editFilter.stations, value: station)
                    }
                }
            }
        }
    }

    // MARK: - Ownership Chips

    @ViewBuilder
    private var ownershipChipsContent: some View {
        FlowLayout(spacing: 6) {
            ForEach(OwnershipType.allCases, id: \.self) { type in
                FilterChip(
                    label: type.rawValue,
                    isSelected: editFilter.ownershipTypes.contains(type)
                ) {
                    if editFilter.ownershipTypes.contains(type) {
                        editFilter.ownershipTypes.remove(type)
                    } else {
                        editFilter.ownershipTypes.insert(type)
                    }
                }
            }
        }
    }

    // MARK: - Ward Grid

    @ViewBuilder
    private var wardGridContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(wardGroups, id: \.area) { group in
                Text(group.area)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                    ForEach(group.wards, id: \.self) { ward in
                        let inData = availableWards.contains(ward)
                        let isSelected = editFilter.wards.contains(ward)
                        Button {
                            toggleSet(&editFilter.wards, value: ward)
                        } label: {
                            Text(ward)
                                .font(.caption2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    isSelected
                                        ? Color.accentColor.opacity(0.10)
                                        : Color(.systemBackground)
                                )
                                .foregroundStyle(
                                    isSelected ? Color.accentColor : (inData ? Color.primary : Color.primary.opacity(0.2))
                                )
                                .fontWeight(isSelected ? .semibold : .regular)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            isSelected ? Color.accentColor.opacity(0.3) : Color(.separator).opacity(0.5),
                                            lineWidth: 1
                                        )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func toggleSet(_ set: inout Set<String>, value: String) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }
}

// MARK: - FilterAccordion

private struct FilterAccordion<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    if summary != "指定なし" {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
        }
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Color.accentColor : Color(.systemBackground))
                .foregroundStyle(isSelected ? .white : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.accentColor : Color(.separator).opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    ListingFilterSheet(
        filter: .constant(ListingFilter()),
        availableLayouts: ["1LDK", "2LDK", "3LDK", "4LDK+"],
        availableWards: ["江東区", "中央区", "港区"],
        availableStations: ["目白", "雑司が谷", "豊洲", "有明"],
        filteredCount: 12
    )
}
