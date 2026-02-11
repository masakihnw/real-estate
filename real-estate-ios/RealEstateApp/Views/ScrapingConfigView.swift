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

    private let scrapingService = ScrapingConfigService.shared

    init(initialConfig: ScrapingConfig) {
        _config = State(initialValue: initialConfig)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !scrapingService.isAuthenticated {
                    Section {
                        Label("ログインするとスクレイピング条件を編集できます", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    priceSection
                    areaSection
                    walkSection
                    builtYearSection
                    totalUnitsSection
                    layoutSection
                    lineKeywordsSection
                }
            }
            .navigationTitle("スクレイピング条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                if scrapingService.isAuthenticated {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await save() }
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("保存")
                            }
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .onAppear {
                config = scrapingService.config
            }
            .alert("保存しました", isPresented: $showSaveSuccess) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("次回のスクレイピングから反映されます。")
            }
            .alert("保存に失敗しました", isPresented: .init(
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
                Text("価格（下限）")
                Spacer()
                numericField("万円", value: $config.priceMinMan)
            }
            HStack {
                Text("価格（上限）")
                Spacer()
                numericField("万円", value: $config.priceMaxMan)
            }
        } header: {
            Text("価格帯")
        } footer: {
            Text("例: 7,500万〜1億円")
        }
    }

    private var areaSection: some View {
        Section {
            HStack {
                Text("専有面積（最小）")
                Spacer()
                numericField("㎡", value: $config.areaMinM2)
            }
            HStack {
                Text("専有面積（上限）")
                Spacer()
                numericFieldOptional("未指定", value: $config.areaMaxM2)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("専有面積")
                Text("💡 住宅ローン控除: 登記簿面積50㎡以上が対象（所得1,000万以下なら40㎡以上）")
                    .font(.caption2)
                    .fontWeight(.regular)
                    .textCase(nil)
            }
        } footer: {
            Text("上限を0にすると未指定（最小のみ適用）")
        }
    }

    private var walkSection: some View {
        Section {
            Stepper(value: $config.walkMinMax, in: 1...20) {
                HStack {
                    Text("駅徒歩")
                    Spacer()
                    Text("\(config.walkMinMax)分以内")
                }
            }
        } header: {
            Text("駅徒歩")
        }
    }

    /// 築年（竣工年）ピッカーの選択肢範囲
    private var builtYearRange: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array((currentYear - 50)...currentYear).reversed()
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
                Text("築年")
                Text("🏗️ 新耐震基準: 1981年6月以降に建築確認を受けた建物が対象（概ね1983年以降竣工）")
                    .font(.caption2)
                    .fontWeight(.regular)
                    .textCase(nil)
            }
        }
    }

    private var totalUnitsSection: some View {
        Section {
            HStack {
                Text("総戸数（最小）")
                Spacer()
                numericField("戸", value: $config.totalUnitsMin)
            }
        } header: {
            Text("総戸数")
        } footer: {
            Text("この戸数以上のマンションを対象。例: 50")
        }
    }

    /// 間取りプレフィックスの選択肢
    private static let layoutPrefixes: [(prefix: String, label: String)] = [
        ("1", "1LDK系"),
        ("2", "2LDK系"),
        ("3", "3LDK系"),
        ("4", "4LDK系"),
        ("5+", "5LDK以上"),
    ]

    private var layoutSection: some View {
        Section {
            FlowLayout(spacing: 8) {
                ForEach(Self.layoutPrefixes, id: \.prefix) { item in
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
            Text("間取り")
        } footer: {
            Text("1LDK系: 1LDK, 1DK 等。5LDK以上: 5LDK, 6LDK 等。タップで切替")
        }
    }

    /// チップ選択用の路線キーワード一覧（SUUMO の station_line に含まれる文字列でマッチ）
    private static let allLineKeywords = [
        "ＪＲ", "東京メトロ", "都営",
        "東急", "京急", "京成", "東武", "西武", "小田急", "京王", "相鉄",
        "つくばエクスプレス", "モノレール", "舎人ライナー",
        "ゆりかもめ", "りんかい",
    ]

    private var lineKeywordsSection: some View {
        Section {
            FlowLayout(spacing: 6) {
                ForEach(Self.allLineKeywords, id: \.self) { keyword in
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
            Text("路線")
        } footer: {
            Text(config.allowedLineKeywords.isEmpty
                 ? "未選択: 全路線が対象になります"
                 : "選択した路線のみ対象。タップで切替")
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

        let toSave = config
        // allowedLineKeywords が空 → 全路線対象（フィルタなし）

        isSaving = true
        defer { isSaving = false }

        do {
            try await scrapingService.save(toSave)
            showSaveSuccess = true
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    ScrapingConfigView(initialConfig: .defaults)
}
