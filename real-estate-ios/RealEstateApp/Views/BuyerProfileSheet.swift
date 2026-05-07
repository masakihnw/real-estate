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

                Section("エリア・ライフスタイル希望") {
                    profileField("街の雰囲気", text: $profile.neighborhoodPreference, placeholder: "例：ファミリー層が多く安心感のある住宅街")
                    profileField("学区・教育", text: $profile.schoolPriority, placeholder: "例：公立小学校の評判重視 / 私立予定なので不問")
                    profileField("通勤の質", text: $profile.commuteQuality, placeholder: "例：乗換1回以内、座れるとなお良い")
                    profileField("休日の過ごし方", text: $profile.weekendLifestyle, placeholder: "例：公園で子どもと遊ぶ / カフェ巡り")
                    profileField("コミュニティ", text: $profile.communityPreference, placeholder: "例：ファミリー世帯が多いエリア希望")
                    profileField("絶対NG条件", text: $profile.dealBreakers, placeholder: "例：ハザード高リスク、1階、北向きのみ")
                }

                Section("住まい") {
                    profileField("現在の住居", text: $profile.currentHousing, placeholder: "例：賃貸 / 持ち家（売却予定）")
                }

                Section("資金計画") {
                    profileField("世帯年収", text: $profile.householdIncome, placeholder: "例：（金額）")
                    profileField("自己資金", text: $profile.selfFunds, placeholder: "例：なし（フルローン）")
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
