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

    // ライフスタイル希望
    var neighborhoodPreference: String
    var schoolPriority: String
    var commuteQuality: String
    var weekendLifestyle: String
    var communityPreference: String
    var dealBreakers: String

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

        let lifestyleFields: [(String, String)] = [
            ("街の雰囲気の好み", neighborhoodPreference),
            ("学区・教育方針", schoolPriority),
            ("通勤の質の重視点", commuteQuality),
            ("休日の過ごし方", weekendLifestyle),
            ("コミュニティ希望", communityPreference),
            ("絶対NG条件", dealBreakers),
        ]
        let hasLifestyle = lifestyleFields.contains { !$0.1.isEmpty }
        if hasLifestyle {
            md += "\n### ライフスタイル希望\n\n"
            md += "| 項目 | 内容 |\n|---|---|\n"
            for (label, value) in lifestyleFields where !value.isEmpty {
                md += "| \(label) | \(value) |\n"
            }
        }
        return md
    }

    /// 初回起動時のデフォルト値（ユーザー情報プリセット済み）
    static let preset = BuyerProfile(
        familyComposition: "夫（1997年生まれ）・妻（1996年生まれ）、子どもなし",
        householdIncome: "（金額）",
        selfFunds: "なし（フルローン）",
        plannedBorrowing: "物件価格全額（上限1.2億円）",
        interestType: .variable,
        estimatedRate: "0.8〜0.9%",
        repaymentYears: "50年",
        monthlyPaymentLimit: "（金額）円（管理費・修繕積立金込み）",
        workStyle: "夫：基本出社（随時リモート可）、妻：週1リモート・関西/東海に隔週出張あり",
        childPlan: "今年1人目予定、2〜3年後に2人目、さらに2〜3年後に3人目（3人目は状況次第）",
        relocationReason: "子どもの増加・成長に伴い手狭になるため。5〜10年単位で住み替え続ける予定",
        postSaleStrategy: .sellOnly,
        priorities: "1.資産性（5〜10年後にマイナスにならないか） 2.間取り（LDK隣接でない独立した部屋＝赤ちゃん寝室用） 3.広さ（60㎡以上希望） 4.エリア（都心アクセス）",
        currentHousing: "賃貸",
        neighborhoodPreference: "ファミリー層が多く安心感のある住宅街、かつ日常買い物に困らない",
        schoolPriority: "公立小学校の評判重視（3人通う予定のため学区の安定性が重要）",
        commuteQuality: "夫：乗換1回以内で30分圏内、座れるとなお良い。妻：新幹線駅アクセスも考慮",
        weekendLifestyle: "公園や子連れスポットが徒歩圏内にほしい",
        communityPreference: "同世代のファミリー世帯が多いエリアが理想",
        dealBreakers: "ハザード高リスク、1階、北向きのみ、総戸数20戸以下"
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
        currentHousing: "",
        neighborhoodPreference: "",
        schoolPriority: "",
        commuteQuality: "",
        weekendLifestyle: "",
        communityPreference: "",
        dealBreakers: ""
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

// MARK: - Codable 後方互換（v1 データに新フィールドがなくても読める）

extension BuyerProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        familyComposition = try c.decode(String.self, forKey: .familyComposition)
        householdIncome = try c.decode(String.self, forKey: .householdIncome)
        selfFunds = try c.decode(String.self, forKey: .selfFunds)
        plannedBorrowing = try c.decode(String.self, forKey: .plannedBorrowing)
        interestType = try c.decode(InterestType.self, forKey: .interestType)
        estimatedRate = try c.decode(String.self, forKey: .estimatedRate)
        repaymentYears = try c.decode(String.self, forKey: .repaymentYears)
        monthlyPaymentLimit = try c.decode(String.self, forKey: .monthlyPaymentLimit)
        workStyle = try c.decode(String.self, forKey: .workStyle)
        childPlan = try c.decode(String.self, forKey: .childPlan)
        relocationReason = try c.decode(String.self, forKey: .relocationReason)
        postSaleStrategy = try c.decode(PostSaleStrategy.self, forKey: .postSaleStrategy)
        priorities = try c.decode(String.self, forKey: .priorities)
        currentHousing = try c.decode(String.self, forKey: .currentHousing)
        neighborhoodPreference = try c.decodeIfPresent(String.self, forKey: .neighborhoodPreference) ?? ""
        schoolPriority = try c.decodeIfPresent(String.self, forKey: .schoolPriority) ?? ""
        commuteQuality = try c.decodeIfPresent(String.self, forKey: .commuteQuality) ?? ""
        weekendLifestyle = try c.decodeIfPresent(String.self, forKey: .weekendLifestyle) ?? ""
        communityPreference = try c.decodeIfPresent(String.self, forKey: .communityPreference) ?? ""
        dealBreakers = try c.decodeIfPresent(String.self, forKey: .dealBreakers) ?? ""
    }
}
