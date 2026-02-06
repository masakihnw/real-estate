//
//  Listing.swift
//  RealEstateApp
//
//  scraping-tool/results/latest.json の1件と対応するモデル
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
        isLiked: Bool = false
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
    }

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

    /// 表示用: 価格（万円）
    var priceDisplay: String {
        guard let p = priceMan else { return "—" }
        return "\(p)万円"
    }

    /// 表示用: 専有面積
    var areaDisplay: String {
        guard let a = areaM2 else { return "—" }
        return String(format: "%.1f㎡", a)
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

    /// stationLine から路線名だけを抽出（例: "東京メトロ南北線「王子」徒歩4分" → "東京メトロ南北線"）
    var lineName: String? {
        guard let line = stationLine,
              let bracket = line.firstIndex(of: "「") else { return nil }
        let name = line[line.startIndex..<bracket].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 表示用: 築年
    var builtDisplay: String {
        guard let y = builtYear else { return builtStr ?? "—" }
        return "築\(y)年"
    }

    /// 表示用: 築年数（現在年 − 竣工年）
    var builtAgeDisplay: String {
        guard let y = builtYear else { return "—" }
        let age = Calendar.current.component(.year, from: .now) - y
        if age <= 0 { return "新築" }
        return "築\(age)年"
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

    /// 表示用: 追加日
    var addedAtDisplay: String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: addedAt)
    }
}

// MARK: - JSON Decoding (latest.json 形式)

struct ListingDTO: Codable {
    var source: String?
    var url: String?
    var name: String?
    var price_man: Int?
    var address: String?
    var station_line: String?
    var walk_min: Int?
    var area_m2: Double?
    var layout: String?
    var built_str: String?
    var built_year: Int?
    var total_units: Int?
    var floor_position: Int?
    var floor_total: Int?
    var floor_structure: String?
    var ownership: String?
    var list_ward_roman: String?
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
            fetchedAt: fetchedAt
        )
    }
}
