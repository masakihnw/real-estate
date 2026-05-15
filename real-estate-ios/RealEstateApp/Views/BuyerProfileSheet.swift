//
//  BuyerProfileSheet.swift
//  RealEstateApp
//
//  AI 相談に使う「買い手条件」を入力・編集するシート。
//  折りたたみセクション + 構造化入力で編集しやすくする。
//

import SwiftUI

struct BuyerProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: BuyerProfile
    @State private var isSaving = false

    init() {
        _profile = State(initialValue: BuyerProfile.load())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("AI に物件の購入判断を相談する際、あなたの条件を伝えることで「一般論」ではなく「あなたの状況に即した判断」を得られます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                familySection
                areaSection
                financeSection
                futurePlanSection
                scenarioSection
            }
            .navigationTitle("買い手条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveProfile()
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaving)
                }
            }
        }
    }

    // MARK: - 家族・ライフスタイル

    private var familySection: some View {
        Section("家族・ライフスタイル") {
            profileField("家族構成", text: $profile.familyComposition, placeholder: "例：30代共働き夫婦、子ども1人（3歳）")
            profileField("働き方", text: $profile.workStyle, placeholder: "例：夫は週4出社、妻はフルリモート")
            profileField("子ども予定", text: $profile.childPlan, placeholder: "例：もう1人希望、2年以内")
            profileField("重視する点", text: $profile.priorities, placeholder: "例：1.資産価値 2.通勤利便 3.子育て環境")
        }
    }

    // MARK: - エリア・住環境

    private var areaSection: some View {
        Section("エリア・住環境") {
            profileField("街の雰囲気", text: $profile.neighborhoodPreference, placeholder: "例：ファミリー層が多く安心感のある住宅街")
            profileField("学区・教育", text: $profile.schoolPriority, placeholder: "例：公立小学校の評判重視 / 私立予定なので不問")
            profileField("通勤の質", text: $profile.commuteQuality, placeholder: "例：乗換1回以内、座れるとなお良い")
            profileField("休日の過ごし方", text: $profile.weekendLifestyle, placeholder: "例：公園で子どもと遊ぶ / カフェ巡り")
            profileField("コミュニティ", text: $profile.communityPreference, placeholder: "例：ファミリー世帯が多いエリア希望")
            profileField("絶対NG条件", text: $profile.dealBreakers, placeholder: "例：ハザード高リスク、1階、北向きのみ")

            chipEditor(title: "希望エリア", items: $profile.preferredAreas, placeholder: "区名を入力")
            chipEditor(title: "必須設備", items: $profile.mustHaveFeatures, placeholder: "設備名を入力")
        }
    }

    // MARK: - 資金計画

    private var financeSection: some View {
        Section("資金計画") {
            incomePicker
            profileField("自己資金", text: $profile.selfFunds, placeholder: "例：なし（フルローン）")
            profileField("借入予定額", text: $profile.plannedBorrowing, placeholder: "例：5,000万円")

            Picker("金利タイプ", selection: $profile.interestType) {
                ForEach(BuyerProfile.InterestType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            ratePicker
            repaymentYearsPicker
            paymentLimitStepper
        }
    }

    // MARK: - 将来の計画

    private var futurePlanSection: some View {
        Section("将来の計画") {
            housingPicker
            profileField("住み替え理由", text: $profile.relocationReason, placeholder: "例：子の進学に合わせて広い戸建てへ")

            Picker("売却後の方針", selection: $profile.postSaleStrategy) {
                ForEach(BuyerProfile.PostSaleStrategy.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)

            timelinePicker
            riskTolerancePicker
        }
    }

    // MARK: - シナリオ

    private var scenarioSection: some View {
        Section("シナリオ") {
            scenarioList(title: "ライフシナリオ", scenarios: $profile.lifeScenarios)
            scenarioList(title: "予算シナリオ", scenarios: $profile.budgetScenarios)
        }
    }

    // MARK: - 構造化入力コンポーネント

    private var incomePicker: some View {
        let incomeOptions = ["800万円", "1,000万円", "（金額）", "1,500万円", "2,000万円", "2,500万円以上"]
        return Picker("世帯年収", selection: $profile.householdIncome) {
            ForEach(incomeOptions, id: \.self) { option in
                Text(option).tag(option)
            }
            if !incomeOptions.contains(profile.householdIncome) && !profile.householdIncome.isEmpty {
                Text(profile.householdIncome).tag(profile.householdIncome)
            }
        }
    }

    private var ratePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("想定金利")
                .font(.caption)
                .foregroundStyle(.secondary)
            if profile.estimatedRate.isEmpty {
                TextField("例：0.8〜0.9%", text: $profile.estimatedRate)
                    .textFieldStyle(.plain)
            } else {
                TextField("想定金利", text: $profile.estimatedRate)
                    .textFieldStyle(.plain)
            }
        }
    }

    private var repaymentYearsPicker: some View {
        let options = ["25年", "30年", "35年", "40年", "45年", "50年"]
        return Picker("返済期間", selection: $profile.repaymentYears) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
            if !options.contains(profile.repaymentYears) && !profile.repaymentYears.isEmpty {
                Text(profile.repaymentYears).tag(profile.repaymentYears)
            }
        }
    }

    private var paymentLimitStepper: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("月額の無理ない上限")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("例：月20万円まで", text: $profile.monthlyPaymentLimit)
                .textFieldStyle(.plain)
        }
    }

    private var housingPicker: some View {
        let options = ["賃貸", "持ち家（売却予定）", "持ち家（そのまま）", "実家"]
        return Picker("現在の住居", selection: $profile.currentHousing) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
            if !options.contains(profile.currentHousing) && !profile.currentHousing.isEmpty {
                Text(profile.currentHousing).tag(profile.currentHousing)
            }
        }
    }

    private var timelinePicker: some View {
        let options = ["半年以内", "1年以内", "2年以内", "特に決めていない"]
        return Picker("購入時期", selection: $profile.timeline) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
            if !options.contains(profile.timeline) && !profile.timeline.isEmpty {
                Text(profile.timeline).tag(profile.timeline)
            }
        }
    }

    private var riskTolerancePicker: some View {
        let options = ["保守的", "中程度", "積極的"]
        return Picker("リスク許容度", selection: $profile.riskTolerance) {
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
            if !options.contains(profile.riskTolerance) && !profile.riskTolerance.isEmpty {
                Text(profile.riskTolerance).tag(profile.riskTolerance)
            }
        }
    }

    // MARK: - チップ入力

    private func chipEditor(title: String, items: Binding<[String]>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(items.wrappedValue, id: \.self) { item in
                    chipView(text: item) {
                        items.wrappedValue.removeAll { $0 == item }
                    }
                }
            }

            ChipInputField(placeholder: placeholder) { newItem in
                if !newItem.isEmpty && !items.wrappedValue.contains(newItem) {
                    items.wrappedValue.append(newItem)
                }
            }
        }
    }

    private func chipView(text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.fill.tertiary)
        .clipShape(Capsule())
    }

    // MARK: - シナリオリスト

    private func scenarioList(title: String, scenarios: Binding<[[String: String]]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(scenarios.wrappedValue.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    TextField("シナリオ名", text: Binding(
                        get: { scenarios.wrappedValue[index]["name"] ?? "" },
                        set: { scenarios.wrappedValue[index]["name"] = $0 }
                    ))
                    .font(.subheadline.weight(.medium))

                    TextField("説明", text: Binding(
                        get: { scenarios.wrappedValue[index]["description"] ?? "" },
                        set: { scenarios.wrappedValue[index]["description"] = $0 }
                    ), axis: .vertical)
                    .font(.caption)
                }
                .padding(8)
                .background(.fill.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .swipeActions {
                    Button(role: .destructive) {
                        scenarios.wrappedValue.remove(at: index)
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }

            Button {
                scenarios.wrappedValue.append(["name": "", "description": ""])
            } label: {
                Label("追加", systemImage: "plus.circle")
                    .font(.caption)
            }
        }
    }

    // MARK: - 共通フィールド

    private func profileField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
        }
    }

    // MARK: - Save

    private func saveProfile() {
        isSaving = true
        profile.save()
        Task {
            await BuyerProfileSyncService.shared.push(profile)
            isSaving = false
            dismiss()
        }
    }
}

// MARK: - チップ入力フィールド

private struct ChipInputField: View {
    let placeholder: String
    let onAdd: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
                .onSubmit {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onAdd(trimmed)
                        text = ""
                    }
                }
            Button {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    onAdd(trimmed)
                    text = ""
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

