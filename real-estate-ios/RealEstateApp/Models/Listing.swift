//
//  Listing.swift
//  RealEstateApp
//
//  scraping-tool/results/latest.json / latest_shinchiku.json の1件と対応するモデル
//

import Foundation
import SwiftData

@Model
final class Listing {
    var source: String?
    var url: String
    var name: String
    var priceMan: Int?
    var address: String?
    var stationLine: String?
    var walkMin: Int?
    var areaM2: Double?
    var layout: String?
    var builtStr: String?
    var builtYear: Int?
    var totalUnits: Int?
    var floorPosition: Int?
    var floorTotal: Int?
    var floorStructure: String?
    var ownership: String?
    var listWardRoman: String?
    var fetchedAt: Date

    /// このリストに初めて追加された日時（同期では上書きしない）
    var addedAt: Date

    /// ユーザーが付けたメモ・コメント（同期では上書きしない）
    var memo: String?
    /// いいね（同期では上書きしない）
    var isLiked: Bool
    /// サイトから掲載が終了した（JSON から消えた）物件
    var isDelisted: Bool

    // MARK: - 新築対応フィールド

    /// 物件種別: "chuko" or "shinchiku"
    var propertyType: String

    /// 価格帯上限（万円）— 新築の価格レンジ用。中古は nil。
    var priceMaxMan: Int?

    /// 面積幅上限（㎡）— 新築の面積レンジ用。中古は nil。
    var areaMaxM2: Double?

    /// 引渡時期 — 新築のみ（例: "2027年9月上旬予定"）。中古は nil。
    var deliveryDate: String?

    /// ジオコーディング済み緯度（キャッシュ用）
    var latitude: Double?
    /// ジオコーディング済み経度（キャッシュ用）
    var longitude: Double?

    // MARK: - 住まいサーフィン評価データ

    /// 沖式儲かる確率 (%)
    var ssProfitPct: Int?
    /// 沖式新築時価 or 沖式時価 (万円, 70m2換算)
    var ssOkiPrice70m2: Int?
    /// 割安判定 ("割安"/"適正"/"割高")
    var ssValueJudgment: String?
    /// 駅ランキング (e.g. "3/12")
    var ssStationRank: String?
    /// 区ランキング (e.g. "8/45")
    var ssWardRank: String?
    /// 住まいサーフィンページURL
    var ssSumaiSurfinURL: String?
    /// 中古値上がり率 (%, e.g. 18.5 or -3.2)
    var ssAppreciationRate: Double?
    /// お気に入りランキングスコア (点)
    var ssFavoriteCount: Int?
    /// 購入判定 (e.g. "購入が望ましい")
    var ssPurchaseJudgment: String?

    // MARK: - ハザード情報
    /// ハザード情報 JSON 文字列
    /// 例: {"flood":true,"sediment":false,"storm_surge":true,"tsunami":false,
    ///       "liquefaction":true,"inland_water":false,"building_collapse":3,"fire":2,"combined":3}
    var hazardInfo: String?

    // MARK: - 値上がりシミュレーション (万円)
    /// ベストケース 5年後
    var ssSimBest5yr: Int?
    /// ベストケース 10年後
    var ssSimBest10yr: Int?
    /// 標準ケース 5年後
    var ssSimStandard5yr: Int?
    /// 標準ケース 10年後
    var ssSimStandard10yr: Int?
    /// ワーストケース 5年後
    var ssSimWorst5yr: Int?
    /// ワーストケース 10年後
    var ssSimWorst10yr: Int?

    init(
        source: String? = nil,
        url: String,
        name: String,
        priceMan: Int? = nil,
        address: String? = nil,
        stationLine: String? = nil,
        walkMin: Int? = nil,
        areaM2: Double? = nil,
        layout: String? = nil,
        builtStr: String? = nil,
        builtYear: Int? = nil,
        totalUnits: Int? = nil,
        floorPosition: Int? = nil,
        floorTotal: Int? = nil,
        floorStructure: String? = nil,
        ownership: String? = nil,
        listWardRoman: String? = nil,
        fetchedAt: Date = .now,
        addedAt: Date = .now,
        memo: String? = nil,
        isLiked: Bool = false,
        isDelisted: Bool = false,
        propertyType: String = "chuko",
        priceMaxMan: Int? = nil,
        areaMaxM2: Double? = nil,
        deliveryDate: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        hazardInfo: String? = nil,
        ssProfitPct: Int? = nil,
        ssOkiPrice70m2: Int? = nil,
        ssValueJudgment: String? = nil,
        ssStationRank: String? = nil,
        ssWardRank: String? = nil,
        ssSumaiSurfinURL: String? = nil,
        ssAppreciationRate: Double? = nil,
        ssFavoriteCount: Int? = nil,
        ssPurchaseJudgment: String? = nil,
        ssSimBest5yr: Int? = nil,
        ssSimBest10yr: Int? = nil,
        ssSimStandard5yr: Int? = nil,
        ssSimStandard10yr: Int? = nil,
        ssSimWorst5yr: Int? = nil,
        ssSimWorst10yr: Int? = nil
    ) {
        self.source = source
        self.url = url
        self.name = name
        self.priceMan = priceMan
        self.address = address
        self.stationLine = stationLine
        self.walkMin = walkMin
        self.areaM2 = areaM2
        self.layout = layout
        self.builtStr = builtStr
        self.builtYear = builtYear
        self.totalUnits = totalUnits
        self.floorPosition = floorPosition
        self.floorTotal = floorTotal
        self.floorStructure = floorStructure
        self.ownership = ownership
        self.listWardRoman = listWardRoman
        self.fetchedAt = fetchedAt
        self.addedAt = addedAt
        self.memo = memo
        self.isLiked = isLiked
        self.isDelisted = isDelisted
        self.propertyType = propertyType
        self.priceMaxMan = priceMaxMan
        self.areaMaxM2 = areaMaxM2
        self.deliveryDate = deliveryDate
        self.latitude = latitude
        self.longitude = longitude
        self.hazardInfo = hazardInfo
        self.ssProfitPct = ssProfitPct
        self.ssOkiPrice70m2 = ssOkiPrice70m2
        self.ssValueJudgment = ssValueJudgment
        self.ssStationRank = ssStationRank
        self.ssWardRank = ssWardRank
        self.ssSumaiSurfinURL = ssSumaiSurfinURL
        self.ssAppreciationRate = ssAppreciationRate
        self.ssFavoriteCount = ssFavoriteCount
        self.ssPurchaseJudgment = ssPurchaseJudgment
        self.ssSimBest5yr = ssSimBest5yr
        self.ssSimBest10yr = ssSimBest10yr
        self.ssSimStandard5yr = ssSimStandard5yr
        self.ssSimStandard10yr = ssSimStandard10yr
        self.ssSimWorst5yr = ssSimWorst5yr
        self.ssSimWorst10yr = ssSimWorst10yr
    }

    // MARK: - Identity

    /// 同一物件判定用（report_utils.identity_key 相当）。価格は含めない。
    var identityKey: String {
        [
            name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: ""),
            layout ?? "",
            areaM2.map { "\($0)" } ?? "",
            address ?? "",
            builtYear.map { "\($0)" } ?? "",
            stationLine ?? "",
            walkMin.map { "\($0)" } ?? ""
        ].joined(separator: "|")
    }

    var isShinchiku: Bool { propertyType == "shinchiku" }

    // MARK: - Display Properties

    /// 表示用: 価格（万円）— 新築は帯表示対応
    var priceDisplay: String {
        if let lo = priceMan {
            if let hi = priceMaxMan, hi != lo {
                return "\(lo)万〜\(hi)万円"
            }
            return "\(lo)万円"
        }
        return isShinchiku ? "価格未定" : "—"
    }

    /// 表示用: 専有面積 — 新築は幅表示対応
    var areaDisplay: String {
        if let lo = areaM2 {
            if let hi = areaMaxM2, hi != lo {
                return String(format: "%.0f〜%.0f㎡", lo, hi)
            }
            return String(format: "%.1f㎡", lo)
        }
        return "—"
    }

    /// 表示用: 駅徒歩
    var walkDisplay: String {
        guard let w = walkMin else { return "—" }
        return "徒歩\(w)分"
    }

    /// stationLine から駅名だけを抽出（例: "東京メトロ南北線「王子」徒歩4分" → "王子"）
    var stationName: String? {
        guard let line = stationLine,
              let start = line.firstIndex(of: "「"),
              let end = line.firstIndex(of: "」"),
              start < end else { return nil }
        return String(line[line.index(after: start)..<end])
    }

    /// stationLine から路線名だけを抽出
    var lineName: String? {
        guard let line = stationLine else { return nil }
        // "路線名/駅名 徒歩N分" パターン対応
        if let slash = line.firstIndex(of: "/") {
            let name = line[line.startIndex..<slash].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        if let bracket = line.firstIndex(of: "「") {
            let name = line[line.startIndex..<bracket].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// stationLine から全駅情報をパース（複数駅対応）
    /// 例: "ＪＲ山手線「目白」徒歩4分／東京メトロ副都心線「雑司が谷」徒歩8分"
    ///   → [("ＪＲ山手線「目白」徒歩4分", "目白", 4), ("東京メトロ副都心線「雑司が谷」徒歩8分", "雑司が谷", 8)]
    struct StationInfo: Identifiable {
        let id = UUID()
        let fullText: String    // "路線名「駅名」徒歩X分"
        let stationName: String // "駅名"
        let walkMin: Int?       // 徒歩分数
    }

    var parsedStations: [StationInfo] {
        guard let line = stationLine, !line.isEmpty else { return [] }
        // ／ or / で分割
        let segments = line.components(separatedBy: CharacterSet(charactersIn: "／/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return segments.map { seg in
            // 駅名抽出
            var name = seg
            if let s = seg.firstIndex(of: "「"), let e = seg.firstIndex(of: "」"), s < e {
                name = String(seg[seg.index(after: s)..<e])
            }
            // 徒歩分数抽出
            var walk: Int? = nil
            if let range = seg.range(of: #"徒歩\s*約?\s*(\d+)\s*分"#, options: .regularExpression) {
                let matched = seg[range]
                if let numRange = matched.range(of: #"\d+"#, options: .regularExpression) {
                    walk = Int(matched[numRange])
                }
            }
            return StationInfo(fullText: seg, stationName: name, walkMin: walk)
        }
    }

    /// 最寄駅のテキスト（最初の駅）
    var primaryStationDisplay: String {
        parsedStations.first?.fullText ?? stationLine ?? "—"
    }

    /// 表示用: 築年
    var builtDisplay: String {
        guard let y = builtYear else { return builtStr ?? "—" }
        return "築\(y)年"
    }

    /// 表示用: 築年数（現在年 − 竣工年）
    var builtAgeDisplay: String {
        if isShinchiku { return "新築" }
        guard let y = builtYear else { return "—" }
        let age = Calendar.current.component(.year, from: .now) - y
        if age <= 0 { return "新築" }
        return "築\(age)年"
    }

    /// 表示用: 引渡時期（新築のみ）
    var deliveryDateDisplay: String {
        deliveryDate ?? "—"
    }

    /// 表示用: 階数（○階/○階建）
    var floorDisplay: String {
        let pos = floorPosition.map { "\($0)階" } ?? "—"
        let total = floorTotal.map { "\($0)階建" } ?? ""
        if !total.isEmpty {
            return "\(pos)/\(total)"
        }
        return pos
    }

    /// 表示用: 権利形態（短縮: 所有権 or 定借）
    var ownershipShort: String {
        guard let o = ownership, !o.isEmpty else { return "—" }
        if o.contains("所有権") { return "所有権" }
        if o.contains("借地") { return "定借" }
        return String(o.prefix(4))
    }

    /// 表示用: 総戸数
    var totalUnitsDisplay: String {
        guard let u = totalUnits else { return "—" }
        return "\(u)戸"
    }

    /// 表示用: 追加日（static DateFormatter で毎回のアロケーションを回避）
    private static let addedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    var addedAtDisplay: String {
        Self.addedAtFormatter.string(from: addedAt)
    }

    /// ジオコーディング済みかどうか
    var hasCoordinate: Bool {
        latitude != nil && longitude != nil
    }

    /// 住まいサーフィンのデータがあるかどうか
    var hasSumaiSurfinData: Bool {
        ssProfitPct != nil || ssOkiPrice70m2 != nil || ssValueJudgment != nil
            || ssAppreciationRate != nil || ssFavoriteCount != nil
            || ssSimBest5yr != nil
    }

    /// 値上がりシミュレーションデータがあるか
    var hasSimulationData: Bool {
        ssSimBest5yr != nil && ssSimStandard5yr != nil && ssSimWorst5yr != nil
    }

    /// 表示用: 沖式儲かる確率
    var ssProfitDisplay: String {
        guard let pct = ssProfitPct else { return "—" }
        return "\(pct)%"
    }

    /// 表示用: 沖式時価
    var ssOkiPriceDisplay: String {
        guard let price = ssOkiPrice70m2 else { return "—" }
        return "\(price)万円"
    }

    // MARK: - ハザード情報解析

    /// パース済みハザードデータ
    struct HazardData {
        /// GSI ハザード（Bool 型: 該当エリアかどうか）
        var flood: Bool = false          // 洪水浸水想定
        var sediment: Bool = false       // 土砂災害警戒
        var stormSurge: Bool = false     // 高潮浸水想定
        var tsunami: Bool = false        // 津波浸水想定
        var liquefaction: Bool = false   // 液状化リスク
        var inlandWater: Bool = false    // 内水浸水想定

        /// 東京都地域危険度（ランク 1-5, 0=データなし）
        var buildingCollapse: Int = 0    // 建物倒壊危険度
        var fire: Int = 0               // 火災危険度
        var combined: Int = 0           // 総合危険度

        /// 何らかのハザードに該当するか
        var hasAnyHazard: Bool {
            flood || sediment || stormSurge || tsunami || liquefaction || inlandWater
                || buildingCollapse >= 3 || fire >= 3 || combined >= 3
        }

        /// 該当するハザード種別のラベル配列
        var activeLabels: [(icon: String, label: String, severity: HazardSeverity)] {
            var results: [(String, String, HazardSeverity)] = []
            if flood { results.append(("drop.fill", "洪水浸水", .warning)) }
            if inlandWater { results.append(("drop.fill", "内水浸水", .warning)) }
            if sediment { results.append(("mountain.2.fill", "土砂災害", .danger)) }
            if stormSurge { results.append(("wind", "高潮浸水", .warning)) }
            if tsunami { results.append(("water.waves", "津波浸水", .danger)) }
            if liquefaction { results.append(("waveform.path.ecg", "液状化", .warning)) }
            if buildingCollapse >= 3 {
                let sev: HazardSeverity = buildingCollapse >= 4 ? .danger : .warning
                results.append(("building.2.crop.circle", "建物倒壊 ランク\(buildingCollapse)", sev))
            }
            if fire >= 3 {
                let sev: HazardSeverity = fire >= 4 ? .danger : .warning
                results.append(("flame.fill", "火災 ランク\(fire)", sev))
            }
            if combined >= 3 {
                let sev: HazardSeverity = combined >= 4 ? .danger : .warning
                results.append(("exclamationmark.triangle.fill", "総合危険度 ランク\(combined)", sev))
            }
            return results
        }
    }

    enum HazardSeverity {
        case warning  // 注意（黄〜オレンジ）
        case danger   // 危険（赤）
    }

    /// hazardInfo JSON をパースして HazardData を返す
    var parsedHazardData: HazardData {
        guard let info = hazardInfo,
              let data = info.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HazardData()
        }
        var h = HazardData()
        h.flood = dict["flood"] as? Bool ?? false
        h.sediment = dict["sediment"] as? Bool ?? false
        h.stormSurge = dict["storm_surge"] as? Bool ?? false
        h.tsunami = dict["tsunami"] as? Bool ?? false
        h.liquefaction = dict["liquefaction"] as? Bool ?? false
        h.inlandWater = dict["inland_water"] as? Bool ?? false
        h.buildingCollapse = dict["building_collapse"] as? Int ?? 0
        h.fire = dict["fire"] as? Int ?? 0
        h.combined = dict["combined"] as? Int ?? 0
        return h
    }

    /// ハザードに該当するかどうか（一覧でのバッジ表示用）
    var hasHazardRisk: Bool {
        parsedHazardData.hasAnyHazard
    }
}

// MARK: - JSON Decoding (latest.json / latest_shinchiku.json 形式)

struct ListingDTO: Codable {
    var source: String?
    var property_type: String?
    var url: String?
    var name: String?
    var price_man: Int?
    var price_max_man: Int?
    var address: String?
    var station_line: String?
    var walk_min: Int?
    var area_m2: Double?
    var area_max_m2: Double?
    var layout: String?
    var built_str: String?
    var built_year: Int?
    var delivery_date: String?
    var total_units: Int?
    var floor_position: Int?
    var floor_total: Int?
    var floor_structure: String?
    var ownership: String?
    var list_ward_roman: String?

    // ハザード情報
    var hazard_info: String?

    // 住まいサーフィン評価データ
    var ss_profit_pct: Int?
    var ss_oki_price_70m2: Int?
    var ss_value_judgment: String?
    var ss_station_rank: String?
    var ss_ward_rank: String?
    var ss_sumai_surfin_url: String?
    var ss_appreciation_rate: Double?
    var ss_favorite_count: Int?
    var ss_purchase_judgment: String?
    var ss_sim_best_5yr: Int?
    var ss_sim_best_10yr: Int?
    var ss_sim_standard_5yr: Int?
    var ss_sim_standard_10yr: Int?
    var ss_sim_worst_5yr: Int?
    var ss_sim_worst_10yr: Int?
}

extension Listing {
    static func from(dto: ListingDTO, fetchedAt: Date = .now) -> Listing? {
        guard let url = dto.url, !url.isEmpty,
              let name = dto.name, !name.isEmpty else { return nil }
        return Listing(
            source: dto.source,
            url: url,
            name: name,
            priceMan: dto.price_man,
            address: dto.address,
            stationLine: dto.station_line,
            walkMin: dto.walk_min,
            areaM2: dto.area_m2,
            layout: dto.layout,
            builtStr: dto.built_str,
            builtYear: dto.built_year,
            totalUnits: dto.total_units,
            floorPosition: dto.floor_position,
            floorTotal: dto.floor_total,
            floorStructure: dto.floor_structure,
            ownership: dto.ownership,
            listWardRoman: dto.list_ward_roman,
            fetchedAt: fetchedAt,
            propertyType: dto.property_type ?? "chuko",
            priceMaxMan: dto.price_max_man,
            areaMaxM2: dto.area_max_m2,
            deliveryDate: dto.delivery_date,
            hazardInfo: dto.hazard_info,
            ssProfitPct: dto.ss_profit_pct,
            ssOkiPrice70m2: dto.ss_oki_price_70m2,
            ssValueJudgment: dto.ss_value_judgment,
            ssStationRank: dto.ss_station_rank,
            ssWardRank: dto.ss_ward_rank,
            ssSumaiSurfinURL: dto.ss_sumai_surfin_url,
            ssAppreciationRate: dto.ss_appreciation_rate,
            ssFavoriteCount: dto.ss_favorite_count,
            ssPurchaseJudgment: dto.ss_purchase_judgment,
            ssSimBest5yr: dto.ss_sim_best_5yr,
            ssSimBest10yr: dto.ss_sim_best_10yr,
            ssSimStandard5yr: dto.ss_sim_standard_5yr,
            ssSimStandard10yr: dto.ss_sim_standard_10yr,
            ssSimWorst5yr: dto.ss_sim_worst_5yr,
            ssSimWorst10yr: dto.ss_sim_worst_10yr
        )
    }
}

// MARK: - Listing Identifiable for sheet (stable id = url)

extension Listing: @retroactive Identifiable {
    var id: String { url }
}
