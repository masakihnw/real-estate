//
//  BuyerProfile.swift
//  RealEstateApp
//
//  AI 相談プロンプトに含める「買い手条件」。UserDefaults に永続化する。
//

import Foundation

struct BuyerProfile: Codable, Equatable {
    var familyComposition: String
    var householdIncome: String
    var selfFunds: String
    var plannedBorrowing: String
    var interestType: InterestType
    var estimatedRate: String
    var repaymentYears: String
    var monthlyPaymentLimit: String
    var workStyle: String
    var childPlan: String
    var relocationReason: String
    var postSaleStrategy: PostSaleStrategy
    var priorities: String
    var currentHousing: String

    enum InterestType: String, Codable, CaseIterable {
        case variable = "変動"
        case fixed = "固定"
        case mix = "ミックス"
    }

    enum PostSaleStrategy: String, Codable, CaseIterable {
        case sellOnly = "売却前提"
        case rentalOK = "賃貸転用も許容"
    }

    var isEmpty: Bool {
        familyComposition.isEmpty && householdIncome.isEmpty && selfFunds.isEmpty
    }

    func toMarkdownSection() -> String {
        guard !isEmpty else { return "" }

        var md = "## 購入者プロフィール\n\n"
        md += "| 項目 | 内容 |\n|---|---|\n"
        if !familyComposition.isEmpty { md += "| 家族構成 | \(familyComposition) |\n" }
        if !householdIncome.isEmpty { md += "| 世帯年収 | \(householdIncome) |\n" }
        if !currentHousing.isEmpty { md += "| 現在の住居 | \(currentHousing) |\n" }
        if !selfFunds.isEmpty { md += "| 自己資金 | \(selfFunds) |\n" }
        if !plannedBorrowing.isEmpty { md += "| 借入予定額 | \(plannedBorrowing) |\n" }
        md += "| 金利タイプ | \(interestType.rawValue) |\n"
        if !estimatedRate.isEmpty { md += "| 想定金利 | \(estimatedRate) |\n" }
        if !repaymentYears.isEmpty { md += "| 返済期間 | \(repaymentYears) |\n" }
        if !monthlyPaymentLimit.isEmpty { md += "| 月額の無理ない上限 | \(monthlyPaymentLimit) |\n" }
        if !workStyle.isEmpty { md += "| 働き方 | \(workStyle) |\n" }
        if !childPlan.isEmpty { md += "| 子ども予定 | \(childPlan) |\n" }
        if !relocationReason.isEmpty { md += "| 住み替え理由 | \(relocationReason) |\n" }
        md += "| 売却後の方針 | \(postSaleStrategy.rawValue) |\n"
        if !priorities.isEmpty { md += "| 重視する点 | \(priorities) |\n" }
        return md
    }

    /// 初回起動時のデフォルト値（ユーザー情報プリセット済み）
    static let preset = BuyerProfile(
        familyComposition: "夫（1997年生まれ）・妻（1996年生まれ）、子どもなし",
        householdIncome: "1,200万円",
        selfFunds: "なし（フルローン）",
        plannedBorrowing: "物件価格全額（上限1.2億円）",
        interestType: .variable,
        estimatedRate: "0.8〜0.9%",
        repaymentYears: "50年",
        monthlyPaymentLimit: "26.7万円（管理費・修繕積立金込み）",
        workStyle: "夫：基本出社（随時リモート可）、妻：週1リモート・関西/東海に隔週出張あり",
        childPlan: "今年1人目予定、2〜3年後に2人目、さらに2〜3年後に3人目（3人目は状況次第）",
        relocationReason: "子どもの増加・成長に伴い手狭になるため。5〜10年単位で住み替え続ける予定",
        postSaleStrategy: .sellOnly,
        priorities: "1.資産性（5〜10年後にマイナスにならないか） 2.間取り（LDK隣接でない独立した部屋＝赤ちゃん寝室用） 3.広さ（60㎡以上希望） 4.エリア（都心アクセス）",
        currentHousing: "賃貸"
    )

    static let empty = BuyerProfile(
        familyComposition: "",
        householdIncome: "",
        selfFunds: "",
        plannedBorrowing: "",
        interestType: .variable,
        estimatedRate: "",
        repaymentYears: "",
        monthlyPaymentLimit: "",
        workStyle: "",
        childPlan: "",
        relocationReason: "",
        postSaleStrategy: .sellOnly,
        priorities: "",
        currentHousing: ""
    )

    // MARK: - UserDefaults 永続化

    private static let key = "buyer_profile_v1"

    static func load() -> BuyerProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(BuyerProfile.self, from: data) else {
            return .preset
        }
        return profile
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
