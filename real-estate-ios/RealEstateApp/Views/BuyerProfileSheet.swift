//
//  BuyerProfileSheet.swift
//  RealEstateApp
//
//  AI 相談に使う「買い手条件」を入力・編集するシート。
//

import SwiftUI

struct BuyerProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: BuyerProfile

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

                Section("家族・ライフスタイル") {
                    profileField("家族構成", text: $profile.familyComposition, placeholder: "例：30代共働き夫婦、子ども1人（3歳）")
                    profileField("働き方", text: $profile.workStyle, placeholder: "例：夫は週4出社、妻はフルリモート")
                    profileField("子ども予定", text: $profile.childPlan, placeholder: "例：もう1人希望、2年以内")
                    profileField("重視する点", text: $profile.priorities, placeholder: "例：1.資産価値 2.通勤利便 3.子育て環境")
                }

                Section("資金計画") {
                    profileField("世帯年収", text: $profile.householdIncome, placeholder: "例：1,600万円")
                    profileField("自己資金", text: $profile.selfFunds, placeholder: "例：2,000万円")
                    profileField("借入予定額", text: $profile.plannedBorrowing, placeholder: "例：5,000万円")
                    Picker("金利タイプ", selection: $profile.interestType) {
                        ForEach(BuyerProfile.InterestType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    profileField("想定金利", text: $profile.estimatedRate, placeholder: "例：0.5%（変動）")
                    profileField("返済期間", text: $profile.repaymentYears, placeholder: "例：35年")
                    profileField("月額の無理ない上限", text: $profile.monthlyPaymentLimit, placeholder: "例：月20万円まで")
                }

                Section("10年後の計画") {
                    profileField("住み替え理由", text: $profile.relocationReason, placeholder: "例：子の進学に合わせて広い戸建てへ")
                    Picker("売却後の方針", selection: $profile.postSaleStrategy) {
                        ForEach(BuyerProfile.PostSaleStrategy.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                }
            }
            .navigationTitle("買い手条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        profile.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func profileField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
        }
    }
}
