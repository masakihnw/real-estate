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
        if !selfFunds.isEmpty { md += "| 自己資金 | \(selfFunds) |\n" }
        if !plannedBorrowing.isEmpty { md += "| 借入予定額 | \(plannedBorrowing) |\n" }
        md += "| 金利タイプ | \(interestType.rawValue) |\n"
        if !estimatedRate.isEmpty { md += "| 想定金利 | \(estimatedRate) |\n" }
        if !repaymentYears.isEmpty { md += "| 返済期間 | \(repaymentYears) |\n" }
        if !monthlyPaymentLimit.isEmpty { md += "| 月額の無理ない上限 | \(monthlyPaymentLimit) |\n" }
        if !workStyle.isEmpty { md += "| 働き方 | \(workStyle) |\n" }
        if !childPlan.isEmpty { md += "| 子ども予定 | \(childPlan) |\n" }
        if !relocationReason.isEmpty { md += "| 10年後の住み替え理由 | \(relocationReason) |\n" }
        md += "| 売却後の方針 | \(postSaleStrategy.rawValue) |\n"
        if !priorities.isEmpty { md += "| 重視する点 | \(priorities) |\n" }
        return md
    }

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
        priorities: ""
    )

    // MARK: - UserDefaults 永続化

    private static let key = "buyer_profile_v1"

    static func load() -> BuyerProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(BuyerProfile.self, from: data) else {
            return .empty
        }
        return profile
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
