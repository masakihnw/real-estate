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
    ("多摩エリア", ["杉並区", "中野区"]),
]

// MARK: - Filter Sheet

struct ListingFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FilterTemplateStore.self) private var templateStore
    @Binding var filter: ListingFilter
    let availableLayouts: [String]
    let availableWards: Set<String>
    /// 路線別駅名リスト（路線名順）
    let availableRouteStations: [RouteStations]
    let filteredCount: Int
    /// 新築タブから呼ばれた場合に true（価格未定トグルを表示）
    var showPriceUndecidedToggle: Bool = false

    // キャンセル時に復元するための元フィルタ
    @State private var originalFilter = ListingFilter()
    @State private var didApply = false

    // テンプレート保存用
    @State private var showSaveAlert = false
    @State private var templateName = ""
    // テンプレートリネーム用
    @State private var renamingTemplate: FilterTemplate?
    @State private var renameText = ""

    // 価格の範囲
    private let priceRange: ClosedRange<Double> = 5000...15000
    private let priceStep: Double = 500
    // 徒歩の範囲
    private let walkRange: ClosedRange<Double> = 1...20
    // 面積の範囲
    private let areaRange: ClosedRange<Double> = 45...100

    /// 物件種別フィルタを表示するか（地図タブから呼ばれた場合に true）
    var showPropertyTypeFilter: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 物件種別（地図タブ用）
                    if showPropertyTypeFilter {
                        FilterAccordion(
                            title: "物件種別",
                            summary: propertyTypeSummary
                        ) {
                            propertyTypeChipsContent
                        }
                    }

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

                    // 駅名
                    if !availableRouteStations.isEmpty {
                        FilterAccordion(
                            title: "駅名",
                            summary: stationSummary
                        ) {
                            stationPickerContent
                        }
                    }

                    // 広さ
                    FilterAccordion(
                        title: "広さ",
                        summary: areaSummary
                    ) {
                        areaSliderContent
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
                    didApply = true
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
                    HStack(spacing: 12) {
                        templateMenu
                        Button("リセット") {
                            withAnimation { filter.reset() }
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .alert("テンプレートを保存", isPresented: $showSaveAlert) {
                TextField("テンプレート名", text: $templateName)
                Button("保存") {
                    let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    templateStore.save(name: name, filter: filter)
                    templateName = ""
                }
                Button("キャンセル", role: .cancel) { templateName = "" }
            } message: {
                Text("現在のフィルタ条件に名前を付けて保存します（最大\(FilterTemplateStore.maxTemplates)件）")
            }
            .alert("テンプレート名を変更", isPresented: Binding(
                get: { renamingTemplate != nil },
                set: { if !$0 { renamingTemplate = nil } }
            )) {
                TextField("テンプレート名", text: $renameText)
                Button("変更") {
                    if let t = renamingTemplate {
                        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { templateStore.rename(t, to: name) }
                    }
                    renamingTemplate = nil
                    renameText = ""
                }
                Button("キャンセル", role: .cancel) {
                    renamingTemplate = nil
                    renameText = ""
                }
            }
            .onAppear { originalFilter = filter }
            .onDisappear {
                if !didApply {
                    filter = originalFilter
                }
            }
        }
    }

    // MARK: - Template Menu

    @ViewBuilder
    private var templateMenu: some View {
        Menu {
            Button {
                showSaveAlert = true
            } label: {
                Label("現在の条件を保存…", systemImage: "square.and.arrow.down")
            }
            .disabled(!templateStore.canSave || !filter.isActive)

            if !templateStore.templates.isEmpty {
                Divider()

                ForEach(templateStore.templates) { template in
                    Button {
                        withAnimation { filter = template.filter }
                    } label: {
                        Label(template.name, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }

                Divider()

                Menu {
                    ForEach(templateStore.templates) { template in
                        Button {
                            renameText = template.name
                            renamingTemplate = template
                        } label: {
                            Label(template.name, systemImage: "pencil")
                        }
                    }
                } label: {
                    Label("名前を変更…", systemImage: "pencil")
                }

                Menu {
                    ForEach(templateStore.templates) { template in
                        Button(role: .destructive) {
                            templateStore.delete(template)
                        } label: {
                            Label(template.name, systemImage: "trash")
                        }
                    }
                } label: {
                    Label("削除…", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: templateStore.templates.isEmpty
                  ? "bookmark"
                  : "bookmark.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Summaries

    private var propertyTypeSummary: String {
        filter.propertyType == .all ? "指定なし" : filter.propertyType.rawValue
    }

    private var priceSummary: String {
        if let min = filter.priceMin, let max = filter.priceMax {
            return "\(min)万〜\(max)万"
        } else if let min = filter.priceMin {
            return "\(min)万〜"
        } else if let max = filter.priceMax {
            return "〜\(max)万"
        }
        return "指定なし"
    }

    private var layoutSummary: String {
        filter.layouts.isEmpty ? "指定なし" : filter.layouts.sorted().joined(separator: ", ")
    }

    private var walkSummary: String {
        guard let max = filter.walkMax else { return "指定なし" }
        return "\(max)分以内"
    }

    private var areaSummary: String {
        guard let min = filter.areaMin else { return "指定なし" }
        return "\(Int(min))㎡以上"
    }

    private var ownershipSummary: String {
        if filter.ownershipTypes.isEmpty { return "指定なし" }
        return filter.ownershipTypes.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private var stationSummary: String {
        if filter.stations.isEmpty { return "指定なし" }
        let sorted = filter.stations.sorted()
        if sorted.count <= 3 { return sorted.joined(separator: ", ") }
        return "\(sorted.prefix(2).joined(separator: ", ")) 他\(sorted.count - 2)駅"
    }

    private var wardSummary: String {
        if filter.wards.isEmpty { return "指定なし" }
        let sorted = filter.wards.sorted()
        if sorted.count <= 3 { return sorted.joined(separator: ", ") }
        return "\(sorted.prefix(2).joined(separator: ", ")) 他\(sorted.count - 2)区"
    }

    // MARK: - Price Slider

    @ViewBuilder
    private var priceSliderContent: some View {
        VStack(spacing: 6) {
            let minVal = Double(filter.priceMin ?? Int(priceRange.lowerBound))
            let maxVal = Double(filter.priceMax ?? Int(priceRange.upperBound))
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
                        get: { Double(filter.priceMin ?? Int(priceRange.lowerBound)) },
                        set: { filter.priceMin = Int($0) == Int(priceRange.lowerBound) ? nil : Int($0) }
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
                        get: { Double(filter.priceMax ?? Int(priceRange.upperBound)) },
                        set: { filter.priceMax = Int($0) == Int(priceRange.upperBound) ? nil : Int($0) }
                    ),
                    in: priceRange,
                    step: priceStep
                )
                .tint(.accentColor)
            }
            // 新築タブのみ: 価格未定を含むかどうかのトグル
            if showPriceUndecidedToggle {
                Toggle(isOn: $filter.includePriceUndecided) {
                    Text("価格未定の物件を含む")
                        .font(.caption)
                }
                .tint(.accentColor)
                .padding(.top, 4)
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
                    isSelected: filter.layouts.contains(layout)
                ) {
                    toggleSet(&filter.layouts, value: layout)
                }
            }
        }
    }

    // MARK: - Walk Slider

    @ViewBuilder
    private var walkSliderContent: some View {
        VStack(spacing: 4) {
            let val = Double(filter.walkMax ?? Int(walkRange.upperBound))
            HStack {
                Slider(
                    value: Binding(
                        get: { val },
                        set: { filter.walkMax = Int($0) == Int(walkRange.upperBound) ? nil : Int($0) }
                    ),
                    in: walkRange,
                    step: 1
                )
                .tint(.accentColor)
                Text(filter.walkMax.map { "\($0)分以内" } ?? "指定なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    // MARK: - Station Picker

    @ViewBuilder
    private var stationPickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 選択中の駅を一括クリアボタン
            if !filter.stations.isEmpty {
                Button {
                    withAnimation { filter.stations.removeAll() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                        Text("選択をすべて解除（\(filter.stations.count)駅）")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }

            ForEach(availableRouteStations, id: \.routeName) { routeGroup in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 0) {
                        // 路線内一括選択/解除
                        let allSelected = routeGroup.stationNames.allSatisfy { filter.stations.contains($0) }
                        Button {
                            withAnimation {
                                if allSelected {
                                    for s in routeGroup.stationNames { filter.stations.remove(s) }
                                } else {
                                    for s in routeGroup.stationNames { filter.stations.insert(s) }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                                    .font(.caption)
                                    .foregroundStyle(allSelected ? Color.accentColor : .secondary)
                                Text("すべて選択")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)

                        ForEach(routeGroup.stationNames, id: \.self) { station in
                            let isSelected = filter.stations.contains(station)
                            Button {
                                withAnimation { toggleSet(&filter.stations, value: station) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                        .font(.subheadline)
                                        .foregroundStyle(isSelected ? Color.accentColor : Color(.tertiaryLabel))
                                    Text(station)
                                        .font(.subheadline)
                                        .foregroundStyle(isSelected ? .primary : .secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.leading, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text(routeGroup.routeName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        let count = routeGroup.stationNames.filter { filter.stations.contains($0) }.count
                        if count > 0 {
                            Text("\(count)駅選択中")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .tint(.secondary)
            }
        }
    }

    // MARK: - Area Slider

    @ViewBuilder
    private var areaSliderContent: some View {
        VStack(spacing: 4) {
            let val = filter.areaMin ?? areaRange.lowerBound
            HStack {
                Slider(
                    value: Binding(
                        get: { val },
                        set: { filter.areaMin = $0 <= areaRange.lowerBound ? nil : $0 }
                    ),
                    in: areaRange,
                    step: 5
                )
                .tint(.accentColor)
                Text(filter.areaMin.map { "\(Int($0))㎡以上" } ?? "指定なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
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
                    isSelected: filter.ownershipTypes.contains(type)
                ) {
                    if filter.ownershipTypes.contains(type) {
                        filter.ownershipTypes.remove(type)
                    } else {
                        filter.ownershipTypes.insert(type)
                    }
                }
            }
        }
    }

    // MARK: - Property Type Chips

    @ViewBuilder
    private var propertyTypeChipsContent: some View {
        FlowLayout(spacing: 6) {
            ForEach(PropertyTypeFilter.allCases, id: \.self) { type in
                FilterChip(
                    label: type.rawValue,
                    isSelected: filter.propertyType == type
                ) {
                    filter.propertyType = type
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
                        let isSelected = filter.wards.contains(ward)
                        Button {
                            toggleSet(&filter.wards, value: ward)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            Divider()
        }
        .clipped()
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
        availableRouteStations: [
            RouteStations(routeName: "ＪＲ山手線", stationNames: ["品川", "目黒", "恵比寿"]),
            RouteStations(routeName: "東京メトロ有楽町線", stationNames: ["豊洲", "月島"]),
        ],
        filteredCount: 12,
        showPriceUndecidedToggle: true
    )
    .environment(FilterTemplateStore())
}
