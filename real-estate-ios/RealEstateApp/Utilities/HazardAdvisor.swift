//
//  HazardAdvisor.swift
//  RealEstateApp
//
//  ハザードデータから購入者向け助言・ランク抽出を導出する純粋ロジック。
//  View（ListingDetailView）の private メソッドから切り出し、単体テスト可能にする。
//

import Foundation

enum HazardAdvisor {
    /// マンション購入者向けの注意ポイントを導出する。
    /// 高層階前提で「直接被害は限定的だが共用部・低層に注意」という観点で助言する。
    static func buyerTips(for hazard: Listing.HazardData) -> [String] {
        var tips: [String] = []
        if hazard.flood || hazard.inlandWater {
            tips.append("高層階（3F以上）であれば浸水の直接被害は限定的です。1階・地下駐車場がある場合は要注意。")
        }
        if hazard.liquefaction {
            tips.append("杭基礎のRC造マンションでは建物自体の倒壊リスクは低いですが、周辺インフラへの影響に注意。")
        }
        if hazard.buildingCollapse >= 3 {
            tips.append("築年数と耐震基準（新耐震 1981年以降）を確認してください。")
        }
        if hazard.stormSurge {
            tips.append("台風時の高潮リスク。高層階であれば直接被害は限定的ですが、共用部・エレベーターへの影響に注意。")
        }
        return tips
    }

    /// ラベル末尾の数字をランクとして抽出する（例: "建物倒壊 ランク3" → 3）。
    /// 末尾が数字でない場合は 0 を返す。
    static func rank(fromLabel label: String) -> Int {
        if let last = label.last, let rank = Int(String(last)) {
            return rank
        }
        return 0
    }
}
