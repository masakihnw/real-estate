//
//  BuyerProfile.swift
//  RealEstateApp
//
//  AI 相談プロンプトに含める「買い手条件」。
//  UserDefaults にローカルキャッシュし、Supabase と同期する。
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

    var neighborhoodPreference: String
    var schoolPriority: String
    var commuteQuality: String
    var weekendLifestyle: String
    var communityPreference: String
    var dealBreakers: String

    var lifeScenarios: [[String: String]]
    var budgetScenarios: [[String: String]]
    var preferredAreas: [String]
    var mustHaveFeatures: [String]
    var timeline: String
    var riskTolerance: String

    var updatedAt: Date

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

    // MARK: - Markdown export

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
        if !timeline.isEmpty { md += "| 購入時期 | \(timeline) |\n" }
        if !riskTolerance.isEmpty { md += "| リスク許容度 | \(riskTolerance) |\n" }

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

        if !preferredAreas.isEmpty {
            md += "\n### 希望エリア\n\n\(preferredAreas.joined(separator: "、"))\n"
        }
        if !mustHaveFeatures.isEmpty {
            md += "\n### 必須設備\n\n\(mustHaveFeatures.joined(separator: "、"))\n"
        }

        if !lifeScenarios.isEmpty {
            md += "\n### ライフシナリオ\n\n"
            for scenario in lifeScenarios {
                let name = scenario["name"] ?? ""
                let desc = scenario["description"] ?? ""
                if !name.isEmpty { md += "- **\(name)**: \(desc)\n" }
            }
        }

        if !budgetScenarios.isEmpty {
            md += "\n### 予算シナリオ\n\n"
            for scenario in budgetScenarios {
                let label = scenario["label"] ?? ""
                let value = scenario["value"] ?? ""
                let note = scenario["note"] ?? ""
                if !label.isEmpty {
                    let suffix = note.isEmpty ? "" : "（\(note)）"
                    md += "- **\(label)**: \(value)\(suffix)\n"
                }
            }
        }

        return md
    }

    // MARK: - Presets

    static let preset = BuyerProfile(
        familyComposition: "夫（1997年生まれ）・妻（1996年生まれ）、子どもなし",
        householdIncome: "1,200万円",
        selfFunds: "なし（フルローン）",
        plannedBorrowing: "諸費用(物件価格の約6%)+物件価格全額。FP相談(2026/6/1)で与信最大額までの借入も理論上問題なしと確認。仲介MTG(2026/6/8)以降は予算を二段構えで運用(探索上限1.3億／実質アンカー物件1.1億前後)。試算例は物件1.1億・ペア借入約1.169億・50年・変動・頭金なし。",
        interestType: .variable,
        estimatedRate: "1.3%（FPライフプラン設計時の前提金利）",
        repaymentYears: "50年",
        monthlyPaymentLimit: "実質上限はローン返済30万円/月以内(金利1.5%想定)。総額(管理費・修繕積立金・固定資産税込み)で約33万円/月。制約は①与信枠 ②産休育休期間のキャッシュフロー成立性。資金計画書(2026/6/8)では1.5%でローン約27.7万・2.0%で約30.8万。",
        workStyle: "夫：基本出社（随時リモート可）、勤務地(東京都千代田区一番町4-6) 妻：週1リモート・関西/東海に隔週出張あり、勤務地(東京都港区虎ノ門4-1-28)",
        childPlan: "3人想定（第1子2025年、第2子2027年、第3子2030年）。全員中学から私立・大学は私立文系想定。",
        relocationReason: "子どもの増加・成長に伴い手狭になるため。5〜10年単位で住み替え続ける予定",
        postSaleStrategy: .sellOnly,
        priorities: "1.資産性（5〜10年後の売却時に残債割れしないこと＝最重要） 2.間取り（LDK隣接でない独立した部屋＝赤ちゃん寝室用） 3.広さ（60㎡以上希望） 4.エリア（都心アクセス）",
        currentHousing: "賃貸",
        neighborhoodPreference: "",
        schoolPriority: "",
        commuteQuality: "夫は自転車で45分圏内なら自転車通勤希望(自転車の方が電車通勤よりドアtoドアで所用時間短い場合)",
        weekendLifestyle: "",
        communityPreference: "",
        dealBreakers: "",
        lifeScenarios: [],
        budgetScenarios: [
            ["label": "探索上限", "value": "1.3億円", "note": "売出は査定+5〜10%の割高が常。1.3億売出でも成約1.1億台になり得るため、値下げ待ちでマークする上限として網を広げる"],
            ["label": "実質アンカー", "value": "物件価格1.1億円前後", "note": "月返済30万円以内（金利1.5%想定）で成立する安心圏"],
            ["label": "月返済上限", "value": "ローン返済30万円/月以内", "note": "金利1.5%想定。管理費・修繕積立金・固定資産税を含む総額で約33万円/月"],
            ["label": "1.1億超の判断", "value": "個別判断", "note": "安全余白・値下げ余地・本気度（買い直したくないと思える物件か）で可否を決める。煽りや相場高騰を理由に上限は上げない"],
            ["label": "資金計画(2026/6/8)", "value": "物件1.1億・ペア借入約1.169億・50年・変動", "note": "1.5%でローン約27.7万、2.0%で約30.8万。諸費用約692万はフルローンに含む"],
        ],
        preferredAreas: [],
        mustHaveFeatures: [],
        timeline: "半年以内",
        riskTolerance: "中〜高",
        updatedAt: Date()
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
        dealBreakers: "",
        lifeScenarios: [],
        budgetScenarios: [],
        preferredAreas: [],
        mustHaveFeatures: [],
        timeline: "",
        riskTolerance: "",
        updatedAt: Date()
    )

    // MARK: - UserDefaults 永続化

    private static let key = "buyer_profile_v1"
    private static let updatedAtKey = "buyer_profile_updated_at"

    static func load() -> BuyerProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(BuyerProfile.self, from: data) else {
            return .preset
        }
        return profile
    }

    func save() {
        var copy = self
        copy.updatedAt = Date()
        guard let data = try? JSONEncoder().encode(copy) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    // MARK: - Supabase 変換

    func toSupabaseJSON() -> [String: Any] {
        var json: [String: Any] = [
            "family_composition": familyComposition,
            "household_income": householdIncome,
            "self_funds": selfFunds,
            "planned_borrowing": plannedBorrowing,
            "interest_type": interestType.rawValue,
            "estimated_rate": estimatedRate,
            "repayment_years": repaymentYears,
            "monthly_payment_limit": monthlyPaymentLimit,
            "work_style": workStyle,
            "child_plan": childPlan,
            "relocation_reason": relocationReason,
            "post_sale_strategy": postSaleStrategy.rawValue,
            "priorities": priorities,
            "current_housing": currentHousing,
            "neighborhood_preference": neighborhoodPreference,
            "school_priority": schoolPriority,
            "commute_quality": commuteQuality,
            "weekend_lifestyle": weekendLifestyle,
            "community_preference": communityPreference,
            "deal_breakers": dealBreakers,
            "timeline": timeline,
            "risk_tolerance": riskTolerance,
        ]

        if !lifeScenarios.isEmpty {
            json["life_scenarios"] = lifeScenarios
        }
        if !budgetScenarios.isEmpty {
            json["budget_scenarios"] = budgetScenarios
        }
        if !preferredAreas.isEmpty {
            json["preferred_areas"] = preferredAreas
        }
        if !mustHaveFeatures.isEmpty {
            json["must_have_features"] = mustHaveFeatures
        }

        return json
    }

    static func from(supabaseJSON json: [String: Any]) -> BuyerProfile {
        let interestType = InterestType(rawValue: json["interest_type"] as? String ?? "変動") ?? .variable
        let postSale = PostSaleStrategy(rawValue: json["post_sale_strategy"] as? String ?? "売却前提") ?? .sellOnly

        let updatedStr = json["updated_at"] as? String ?? ""
        let updatedAt = SupabaseListingStore.parseSupabaseTimestamp(updatedStr) ?? Date.distantPast

        return BuyerProfile(
            familyComposition: json["family_composition"] as? String ?? "",
            householdIncome: json["household_income"] as? String ?? "",
            selfFunds: json["self_funds"] as? String ?? "",
            plannedBorrowing: json["planned_borrowing"] as? String ?? "",
            interestType: interestType,
            estimatedRate: json["estimated_rate"] as? String ?? "",
            repaymentYears: json["repayment_years"] as? String ?? "",
            monthlyPaymentLimit: json["monthly_payment_limit"] as? String ?? "",
            workStyle: json["work_style"] as? String ?? "",
            childPlan: json["child_plan"] as? String ?? "",
            relocationReason: json["relocation_reason"] as? String ?? "",
            postSaleStrategy: postSale,
            priorities: json["priorities"] as? String ?? "",
            currentHousing: json["current_housing"] as? String ?? "",
            neighborhoodPreference: json["neighborhood_preference"] as? String ?? "",
            schoolPriority: json["school_priority"] as? String ?? "",
            commuteQuality: json["commute_quality"] as? String ?? "",
            weekendLifestyle: json["weekend_lifestyle"] as? String ?? "",
            communityPreference: json["community_preference"] as? String ?? "",
            dealBreakers: json["deal_breakers"] as? String ?? "",
            lifeScenarios: json["life_scenarios"] as? [[String: String]] ?? [],
            budgetScenarios: json["budget_scenarios"] as? [[String: String]] ?? [],
            preferredAreas: json["preferred_areas"] as? [String] ?? [],
            mustHaveFeatures: json["must_have_features"] as? [String] ?? [],
            timeline: json["timeline"] as? String ?? "",
            riskTolerance: json["risk_tolerance"] as? String ?? "",
            updatedAt: updatedAt
        )
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
        lifeScenarios = try c.decodeIfPresent([[String: String]].self, forKey: .lifeScenarios) ?? []
        budgetScenarios = try c.decodeIfPresent([[String: String]].self, forKey: .budgetScenarios) ?? []
        preferredAreas = try c.decodeIfPresent([String].self, forKey: .preferredAreas) ?? []
        mustHaveFeatures = try c.decodeIfPresent([String].self, forKey: .mustHaveFeatures) ?? []
        timeline = try c.decodeIfPresent(String.self, forKey: .timeline) ?? ""
        riskTolerance = try c.decodeIfPresent(String.self, forKey: .riskTolerance) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}
