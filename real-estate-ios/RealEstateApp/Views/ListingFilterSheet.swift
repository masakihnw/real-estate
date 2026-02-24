//
//  ListingFilterSheet.swift
//  RealEstateApp
//
//  プリセットチップ列 + アコーディオン式フィルタ。
//  改善: チップ列方式 / セクション個別クリア / アクティブ数バッジ / 自動展開
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

// MARK: - プリセット定義

private let pricePresets: [Int] = [5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000, 13000, 14000, 15000]
private let tsuboPresets: [Double] = [200, 250, 300, 350, 400, 450, 500]
private let walkPresets: [Int] = [3, 5, 7, 10, 15, 20]
private let areaPresets: [Double] = [45, 50, 55, 60, 65, 70, 75, 80]

// MARK: - Filter Sheet

struct ListingFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FilterTemplateStore.self) private var templateStore
    @Binding var filter: ListingFilter
    let availableLayouts: [String]
    let availableWards: Set<String>
    let availableRouteStations: [RouteStations]
    let filteredCount: Int
    var showPriceUndecidedToggle: Bool = false
    var showPropertyTypeFilter: Bool = false

    @State private var originalFilter = ListingFilter()
    @State private var didApply = false

    @State private var showSaveAlert = false
    @State private var templateName = ""
    @State private var renamingTemplate: FilterTemplate?
    @State private var renameText = ""

    private var activeFilterCount: Int {
        var count = 0
        if filter.propertyType != .all { count += 1 }
        if filter.priceMin != nil || filter.priceMax != nil || !filter.includePriceUndecided { count += 1 }
        if filter.tsuboUnitPriceMin != nil || filter.tsuboUnitPriceMax != nil { count += 1 }
        if !filter.layouts.isEmpty { count += 1 }
        if filter.walkMax != nil { count += 1 }
        if !filter.stations.isEmpty { count += 1 }
        if filter.areaMin != nil { count += 1 }
        if !filter.ownershipTypes.isEmpty { count += 1 }
        if !filter.wards.isEmpty { count += 1 }
        return count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if showPropertyTypeFilter {
                        FilterAccordion(
                            title: "物件種別",
                            summary: propertyTypeSummary,
                            isActiveSection: filter.propertyType != .all,
                            onClear: { filter.propertyType = .all }
                        ) {
                            propertyTypeChipsContent
                        }
                    }

                    FilterAccordion(
                        title: "価格帯",
                        summary: priceSummary,
                        isActiveSection: filter.priceMin != nil || filter.priceMax != nil || !filter.includePriceUndecided,
                        onClear: { filter.priceMin = nil; filter.priceMax = nil; filter.includePriceUndecided = true }
                    ) {
                        priceChipsContent
                    }

                    FilterAccordion(
                        title: "坪単価",
                        summary: tsuboSummary,
                        isActiveSection: filter.tsuboUnitPriceMin != nil || filter.tsuboUnitPriceMax != nil,
                        onClear: { filter.tsuboUnitPriceMin = nil; filter.tsuboUnitPriceMax = nil }
                    ) {
                        tsuboChipsContent
                    }

                    if !availableLayouts.isEmpty {
                        FilterAccordion(
                            title: "間取り",
                            summary: layoutSummary,
                            isActiveSection: !filter.layouts.isEmpty,
                            onClear: { filter.layouts.removeAll() }
                        ) {
                            layoutChipsContent
                        }
                    }

                    FilterAccordion(
                        title: "駅徒歩",
                        summary: walkSummary,
                        isActiveSection: filter.walkMax != nil,
                        onClear: { filter.walkMax = nil }
                    ) {
                        walkChipsContent
                    }

                    if !availableRouteStations.isEmpty {
                        FilterAccordion(
                            title: "駅名",
                            summary: stationSummary,
                            isActiveSection: !filter.stations.isEmpty,
                            onClear: { filter.stations.removeAll() }
                        ) {
                            stationPickerContent
                        }
                    }

                    FilterAccordion(
                        title: "広さ",
                        summary: areaSummary,
                        isActiveSection: filter.areaMin != nil,
                        onClear: { filter.areaMin = nil }
                    ) {
                        areaChipsContent
                    }

                    FilterAccordion(
                        title: "権利形態",
                        summary: ownershipSummary,
                        isActiveSection: !filter.ownershipTypes.isEmpty,
                        onClear: { filter.ownershipTypes.removeAll() }
                    ) {
                        ownershipChipsContent
                    }

                    FilterAccordion(
                        title: "エリア（区）",
                        summary: wardSummary,
                        isActiveSection: !filter.wards.isEmpty,
                        onClear: { filter.wards.removeAll() }
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
            .navigationTitle(activeFilterCount > 0 ? "フィルタ (\(activeFilterCount))" : "フィルタ")
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
            return "\(formatPrice(min))〜\(formatPrice(max))"
        } else if let min = filter.priceMin {
            return "\(formatPrice(min))〜"
        } else if let max = filter.priceMax {
            return "〜\(formatPrice(max))"
        }
        return "指定なし"
    }

    private var tsuboSummary: String {
        if let min = filter.tsuboUnitPriceMin, let max = filter.tsuboUnitPriceMax {
            return "\(Int(min))〜\(Int(max))万/坪"
        } else if let min = filter.tsuboUnitPriceMin {
            return "\(Int(min))万/坪〜"
        } else if let max = filter.tsuboUnitPriceMax {
            return "〜\(Int(max))万/坪"
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

    // MARK: - Price Chips

    @ViewBuilder
    private var priceChipsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            PresetChipSection(label: "下限") {
                PresetChip(label: "指定なし", isSelected: filter.priceMin == nil) {
                    filter.priceMin = nil
                }
                ForEach(pricePresets.filter { $0 < (filter.priceMax ?? Int.max) }, id: \.self) { value in
                    PresetChip(label: formatPrice(value), isSelected: filter.priceMin == value) {
                        filter.priceMin = value
                    }
                }
            }
            PresetChipSection(label: "上限") {
                ForEach(pricePresets.filter { $0 > (filter.priceMin ?? 0) }, id: \.self) { value in
                    PresetChip(label: formatPrice(value), isSelected: filter.priceMax == value) {
                        filter.priceMax = value
                    }
                }
                PresetChip(label: "指定なし", isSelected: filter.priceMax == nil) {
                    filter.priceMax = nil
                }
            }
            if showPriceUndecidedToggle {
                Toggle(isOn: $filter.includePriceUndecided) {
                    Text("価格未定の物件を含む")
                        .font(.caption)
                }
                .tint(.accentColor)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Tsubo Chips

    @ViewBuilder
    private var tsuboChipsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            PresetChipSection(label: "下限") {
                PresetChip(label: "指定なし", isSelected: filter.tsuboUnitPriceMin == nil) {
                    filter.tsuboUnitPriceMin = nil
                }
                ForEach(tsuboPresets.filter { $0 < (filter.tsuboUnitPriceMax ?? .infinity) }, id: \.self) { value in
                    PresetChip(label: "\(Int(value))万/坪", isSelected: filter.tsuboUnitPriceMin == value) {
                        filter.tsuboUnitPriceMin = value
                    }
                }
            }
            PresetChipSection(label: "上限") {
                ForEach(tsuboPresets.filter { $0 > (filter.tsuboUnitPriceMin ?? 0) }, id: \.self) { value in
                    PresetChip(label: "\(Int(value))万/坪", isSelected: filter.tsuboUnitPriceMax == value) {
                        filter.tsuboUnitPriceMax = value
                    }
                }
                PresetChip(label: "指定なし", isSelected: filter.tsuboUnitPriceMax == nil) {
                    filter.tsuboUnitPriceMax = nil
                }
            }
        }
    }

    // MARK: - Walk Chips

    @ViewBuilder
    private var walkChipsContent: some View {
        PresetChipSection {
            PresetChip(label: "指定なし", isSelected: filter.walkMax == nil) {
                filter.walkMax = nil
            }
            ForEach(walkPresets, id: \.self) { value in
                PresetChip(label: "\(value)分以内", isSelected: filter.walkMax == value) {
                    filter.walkMax = value
                }
            }
        }
    }

    // MARK: - Area Chips

    @ViewBuilder
    private var areaChipsContent: some View {
        PresetChipSection {
            PresetChip(label: "指定なし", isSelected: filter.areaMin == nil) {
                filter.areaMin = nil
            }
            ForEach(areaPresets, id: \.self) { value in
                PresetChip(label: "\(Int(value))㎡以上", isSelected: filter.areaMin == value) {
                    filter.areaMin = value
                }
            }
        }
    }

    // MARK: - Layout Chips

    @ViewBuilder
    private var layoutChipsContent: some View {
        FlowLayout(spacing: 8) {
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

    // MARK: - Ownership Chips

    @ViewBuilder
    private var ownershipChipsContent: some View {
        HStack(spacing: 8) {
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
            Spacer()
        }
    }

    // MARK: - Property Type Chips

    @ViewBuilder
    private var propertyTypeChipsContent: some View {
        FlowLayout(spacing: 8) {
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

    // MARK: - Station Picker

    @ViewBuilder
    private var stationPickerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
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

    // MARK: - Ward Grid

    @ViewBuilder
    private var wardGridContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(wardGroups, id: \.area) { group in
                let selectedCount = group.wards.filter { filter.wards.contains($0) }.count
                let allSelected = selectedCount == group.wards.count
                Button {
                    withAnimation {
                        if allSelected {
                            for w in group.wards { filter.wards.remove(w) }
                        } else {
                            for w in group.wards { filter.wards.insert(w) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : (selectedCount > 0 ? "minus.circle.fill" : "circle"))
                            .font(.subheadline)
                            .foregroundStyle(selectedCount > 0 ? Color.accentColor : .secondary)
                        Text(group.area)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(selectedCount > 0 ? .primary : .secondary)
                        if selectedCount > 0 && !allSelected {
                            Text("\(selectedCount)/\(group.wards.count)")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.top, 6)
                }
                .buttonStyle(.plain)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                    ForEach(group.wards, id: \.self) { ward in
                        let inData = availableWards.contains(ward)
                        let isSelected = filter.wards.contains(ward)
                        Button {
                            toggleSet(&filter.wards, value: ward)
                        } label: {
                            Text(ward)
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
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

    private func formatPrice(_ man: Int) -> String {
        if man >= 10000 {
            let oku = Double(man) / 10000.0
            if oku == oku.rounded() {
                return "\(Int(oku))億"
            }
            return String(format: "%.1f億", oku)
        }
        return "\(man)万"
    }
}

// MARK: - FilterAccordion (with auto-expand & section clear)

private struct FilterAccordion<Content: View>: View {
    let title: String
    let summary: String
    let isActiveSection: Bool
    let onClear: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @State private var isExpanded: Bool? = nil

    init(
        title: String,
        summary: String,
        isActiveSection: Bool = false,
        onClear: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.summary = summary
        self.isActiveSection = isActiveSection
        self.onClear = onClear
        self.content = content
    }

    private var expanded: Bool {
        isExpanded ?? isActiveSection
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded = !expanded
                }
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
                    if isActiveSection, let onClear {
                        Button {
                            withAnimation { onClear() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if expanded {
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

// MARK: - PresetChipSection (horizontal scroll row)

private struct PresetChipSection<Content: View>: View {
    var label: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    content()
                }
            }
        }
    }
}

// MARK: - PresetChip

private struct PresetChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
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

// MARK: - FilterChip (multi-select)

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
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
