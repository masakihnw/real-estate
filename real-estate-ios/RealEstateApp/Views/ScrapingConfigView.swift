//
//  ScrapingConfigView.swift
//  RealEstateApp
//
//  スクレイピング条件の編集画面。
//  設定した条件は Firestore に保存され、次回のスクレイピング実行時に反映される。
//

import SwiftUI

struct ScrapingConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config: ScrapingConfig
    @State private var isSaving = false
    @State private var showSaveSuccess = false
    @State private var saveError: String?
    @State private var saveCorrectionNotice: String?

    private let scrapingService = ScrapingConfigService.shared
    private var metadata: ScrapingConfigMetadata { scrapingService.metadata }
    private var walkRange: ClosedRange<Int> {
        let c = metadata.constraints.walkMinMax
        return c.min...c.max
    }
    private var totalUnitsRange: ClosedRange<Int> {
        let c = metadata.constraints.totalUnitsMin
        return c.min...c.max
    }
    private var priceUnit: String { metadata.units["price"] ?? "万円" }
    private var areaUnit: String { metadata.units["area"] ?? "㎡" }
    private var totalUnitsUnit: String { metadata.units["totalUnits"] ?? "戸" }

    init(initialConfig: ScrapingConfig) {
        _config = State(initialValue: initialConfig)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !scrapingService.isAuthenticated {
                    Section {
                        Label(t("authRequiredMessage", "ログインするとスクレイピング条件を編集できます"), systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    priceSection
                    areaSection
                    walkSection
                    builtYearSection
                    totalUnitsSection
                    layoutSection
                    stationsSection
                    lineKeywordsSection
                }
            }
            .navigationTitle(t("navigationTitle", "スクレイピング条件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(t("closeButton", "閉じる")) { dismiss() }
                }
                if scrapingService.isAuthenticated {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await save() }
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text(t("saveButton", "保存"))
                            }
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .task {
                config = scrapingService.config
            }
            .onChange(of: config) { _, newValue in
                let normalized = newValue.normalized(using: metadata)
                if normalized != newValue {
                    config = normalized
                }
            }
            .alert(t("saveSuccessTitle", "保存しました"), isPresented: $showSaveSuccess) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                if let saveCorrectionNotice, !saveCorrectionNotice.isEmpty {
                    Text("\(t("saveSuccessMessage", "次回のスクレイピングから反映されます。"))\n\(saveCorrectionNotice)")
                } else {
                    Text(t("saveSuccessMessage", "次回のスクレイピングから反映されます。"))
                }
            }
            .alert(t("saveErrorTitle", "保存に失敗しました"), isPresented: .init(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    /// 数値入力フィールド共通スタイル
    private func numericField(_ placeholder: String, value: Binding<Int>) -> some View {
        TextField(placeholder, value: value, format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 100)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )
    }

    /// Optional な数値入力フィールド
    private func numericFieldOptional(_ placeholder: String, value: Binding<Int?>) -> some View {
        TextField(placeholder, value: Binding(
            get: { value.wrappedValue ?? 0 },
            set: { value.wrappedValue = $0 > 0 ? $0 : nil }
        ), format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 100)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )
    }

    private var priceSection: some View {
        Section {
            HStack {
                Text(t("priceMinLabel", "価格（下限）"))
                Spacer()
                numericField(priceUnit, value: $config.priceMinMan)
            }
            HStack {
                Text(t("priceMaxLabel", "価格（上限）"))
                Spacer()
                numericField(priceUnit, value: $config.priceMaxMan)
            }
        } header: {
            Text(t("priceSectionTitle", "価格帯"))
        } footer: {
            Text(t("priceSectionFooter", "例: 7,500万〜1億円"))
        }
    }

    private var areaSection: some View {
        Section {
            HStack {
                Text(t("areaMinLabel", "専有面積（最小）"))
                Spacer()
                numericField(areaUnit, value: $config.areaMinM2)
            }
            HStack {
                Text(t("areaMaxLabel", "専有面積（上限）"))
                Spacer()
                numericFieldOptional("未指定", value: $config.areaMaxM2)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("areaSectionTitle", "専有面積"))
                Text(t("areaSectionInfo", "💡 住宅ローン控除: 登記簿面積50㎡以上が対象（所得1,000万以下なら40㎡以上）"))
                    .font(.caption2)
                    .fontWeight(.regular)
                    .textCase(nil)
            }
        } footer: {
            Text(t("areaSectionFooter", "上限を0にすると未指定（最小のみ適用）"))
        }
    }

    private var walkSection: some View {
        Section {
            Stepper(value: $config.walkMinMax, in: walkRange) {
                HStack {
                    Text(t("walkLabel", "駅徒歩"))
                    Spacer()
                    Text("\(config.walkMinMax)分以内")
                }
            }
        } header: {
            Text(t("walkSectionTitle", "駅徒歩"))
        }
    }

    /// 築年（竣工年）ピッカーの選択肢範囲
    private var builtYearRange: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        let minYear = metadata.constraints.builtYearMin.min
        return Array(minYear...currentYear).reversed()
    }

    private var builtYearSection: some View {
        Section {
            Picker("竣工年", selection: $config.builtYearMin) {
                let currentYear = Calendar.current.component(.year, from: Date())
                ForEach(builtYearRange, id: \.self) { year in
                    let age = currentYear - year
                    Text("\(year)年以降（築\(age)年以内）").tag(year)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("builtYearSectionTitle", "築年"))
                Text(t("builtYearSectionInfo", "🏗️ 新耐震基準: 1981年6月以降に建築確認を受けた建物が対象（概ね1983年以降竣工）"))
                    .font(.caption2)
                    .fontWeight(.regular)
                    .textCase(nil)
            }
        }
    }

    private var totalUnitsSection: some View {
        Section {
            Stepper(value: $config.totalUnitsMin, in: totalUnitsRange) {
                HStack {
                    Text(t("totalUnitsMinLabel", "総戸数（最小）"))
                    Spacer()
                    Text("\(config.totalUnitsMin)\(totalUnitsUnit)")
                }
            }
        } header: {
            Text(t("totalUnitsSectionTitle", "総戸数"))
        } footer: {
            Text(t("totalUnitsFooter", "この戸数以上のマンションを対象。例: 50"))
        }
    }

    private var layoutSection: some View {
        Section {
            FlowLayout(spacing: 8) {
                ForEach(metadata.layoutOptions, id: \.prefix) { item in
                    Button {
                        toggleLayout(item.prefix)
                    } label: {
                        Text(item.label)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                config.layoutPrefixOk.contains(item.prefix)
                                    ? Color.accentColor
                                    : Color(.systemGray5)
                            )
                            .foregroundStyle(
                                config.layoutPrefixOk.contains(item.prefix)
                                    ? .white
                                    : .secondary
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(t("layoutSectionTitle", "間取り"))
        } footer: {
            Text(t("layoutFooter", "1LDK系: 1LDK, 1DK 等。5LDK以上: 5LDK, 6LDK 等。タップで切替"))
        }
    }

    @State private var newStationText = ""

    private var stationsSection: some View {
        Section {
            ForEach(metadata.stationGroups, id: \.line) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(group.stations, id: \.self) { station in
                            Button {
                                toggleStation(station)
                            } label: {
                                Text(station)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        config.allowedStations.contains(station)
                                            ? Color.accentColor
                                            : Color(.systemGray5)
                                    )
                                    .foregroundStyle(
                                        config.allowedStations.contains(station)
                                            ? .white
                                            : .secondary
                                    )
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                TextField(t("stationAddPlaceholder", "駅名を追加"), text: $newStationText)
                    .textFieldStyle(.roundedBorder)
                Button(t("stationAddButton", "追加")) {
                    let name = newStationText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && !config.allowedStations.contains(name) {
                        config.allowedStations.append(name)
                    }
                    newStationText = ""
                }
                .disabled(newStationText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(t("stationsSectionTitle", "対象駅"))
        } footer: {
            Text(config.allowedStations.isEmpty
                 ? t("stationsFooterEmpty", "未選択: 駅名フィルタなし（路線フィルタのみ適用）")
                 : selectedStationsFooter)
        }
    }

    private func toggleStation(_ station: String) {
        if config.allowedStations.contains(station) {
            config.allowedStations.removeAll { $0 == station }
        } else {
            config.allowedStations.append(station)
        }
    }

    private var lineKeywordsSection: some View {
        Section {
            FlowLayout(spacing: 6) {
                ForEach(metadata.lineKeywords, id: \.self) { keyword in
                    Button {
                        toggleLineKeyword(keyword)
                    } label: {
                        Text(keyword)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                config.allowedLineKeywords.contains(keyword)
                                    ? Color.accentColor
                                    : Color(.systemGray5)
                            )
                            .foregroundStyle(
                                config.allowedLineKeywords.contains(keyword)
                                    ? .white
                                    : .secondary
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(t("lineSectionTitle", "路線"))
        } footer: {
            Text(config.allowedLineKeywords.isEmpty
                 ? t("lineFooterEmpty", "未選択: 全路線が対象になります")
                 : t("lineFooterSelected", "選択した路線のみ対象。タップで切替"))
        }
    }

    private func toggleLineKeyword(_ keyword: String) {
        var updated = config.allowedLineKeywords
        if updated.contains(keyword) {
            updated.removeAll { $0 == keyword }
        } else {
            updated.append(keyword)
        }
        config.allowedLineKeywords = updated
    }

    private func toggleLayout(_ prefix: String) {
        var updated = config.layoutPrefixOk
        if updated.contains(prefix) {
            if updated.count > 1 {
                updated.removeAll { $0 == prefix }
            }
        } else {
            updated.append(prefix)
            updated.sort()
        }
        config.layoutPrefixOk = updated
    }

    private func save() async {
        guard scrapingService.isAuthenticated else { return }

        let normalizedToSave = config.normalized(using: metadata)
        saveCorrectionNotice = normalizedToSave == config
            ? nil
            : t("saveCorrectedMessage", "入力値を制約に合わせて補正して保存しました。")

        isSaving = true
        defer { isSaving = false }

        do {
            try await scrapingService.save(normalizedToSave)
            showSaveSuccess = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var selectedStationsFooter: String {
        let template = t("stationsFooterSelectedTemplate", "選択した駅の最寄り物件のみ対象（%d駅）。タップで切替")
        if template.contains("%d") {
            return template.replacingOccurrences(of: "%d", with: "\(config.allowedStations.count)")
        }
        return template
    }

    private func t(_ key: String, _ fallback: String) -> String {
        metadata.uiText[key] ?? fallback
    }
}

#Preview {
    ScrapingConfigView(initialConfig: .defaults)
}
