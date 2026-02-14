//
//  TransactionRecord.swift
//  RealEstateApp
//
//  reinfolib API（不動産情報ライブラリ）の成約実績データを表すモデル。
//  build_transaction_feed.py が生成する transactions.json の1取引に対応する。
//

import Foundation
import SwiftData
import CoreLocation

@Model
final class TransactionRecord: @unchecked Sendable {

    // MARK: - 識別子

    /// ユニーク ID（Python 側で生成: "tx-" + MD5ハッシュ12桁）
    @Attribute(.unique) var txId: String

    // MARK: - 位置情報

    /// 都道府県（例: "東京都"）
    var prefecture: String
    /// 市区町村（例: "江東区"）
    var ward: String
    /// 町丁目（例: "有明"）
    var district: String
    /// 町丁目コード（例: "131080020"）
    var districtCode: String

    // MARK: - 取引情報

    /// 成約価格（万円）
    var priceMan: Int
    /// 専有面積（㎡）
    var areaM2: Double
    /// m² 単価（円/㎡）
    var m2Price: Int
    /// 間取り（例: "3LDK"）
    var layout: String
    /// 築年（例: 2019）
    var builtYear: Int
    /// 構造（例: "RC", "SRC"）
    var structure: String
    /// 取引時期（例: "2025Q2"）
    var tradePeriod: String

    // MARK: - 推定駅情報

    /// 推定最寄駅名（geocode + station_cache.json から算出）
    var nearestStation: String?
    /// 推定徒歩分（直線距離ベース、精度 ±2-3 分）
    var estimatedWalkMin: Int?

    // MARK: - 座標

    /// ジオコーディング済み緯度（町丁目レベル）
    var latitude: Double?
    /// ジオコーディング済み経度（町丁目レベル）
    var longitude: Double?

    // MARK: - グルーピング

    /// 推定建物グループ ID（"districtCode-builtYear"）
    var buildingGroupId: String?

    // MARK: - 推定物件名

    /// スクレイピングデータとのクロスリファレンスで推定した物件名
    /// 複数候補がある場合は " / " 区切り（例: "パークタワー東雲 / ブリリア有明"）
    var estimatedBuildingName: String?

    // MARK: - 初期化

    init(
        txId: String,
        prefecture: String,
        ward: String,
        district: String,
        districtCode: String,
        priceMan: Int,
        areaM2: Double,
        m2Price: Int,
        layout: String,
        builtYear: Int,
        structure: String,
        tradePeriod: String,
        nearestStation: String? = nil,
        estimatedWalkMin: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        buildingGroupId: String? = nil,
        estimatedBuildingName: String? = nil
    ) {
        self.txId = txId
        self.prefecture = prefecture
        self.ward = ward
        self.district = district
        self.districtCode = districtCode
        self.priceMan = priceMan
        self.areaM2 = areaM2
        self.m2Price = m2Price
        self.layout = layout
        self.builtYear = builtYear
        self.structure = structure
        self.tradePeriod = tradePeriod
        self.nearestStation = nearestStation
        self.estimatedWalkMin = estimatedWalkMin
        self.latitude = latitude
        self.longitude = longitude
        self.buildingGroupId = buildingGroupId
        self.estimatedBuildingName = estimatedBuildingName
    }

    // MARK: - Computed

    /// 座標があるか
    var hasCoordinate: Bool {
        latitude != nil && longitude != nil
    }

    /// CLLocationCoordinate2D に変換
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// 表示用住所（例: "東京都江東区有明"）
    var displayAddress: String {
        "\(prefecture)\(ward)\(district)"
    }

    /// 表示用建物名（推定名がなければ住所+築年）
    var displayBuildingName: String {
        if let name = estimatedBuildingName, !name.isEmpty {
            return name
        }
        return "\(ward)\(district) \(builtYear)年築"
    }

    /// 表示用の取引時期（例: "2025年 第2四半期"）
    var displayPeriod: String {
        let parts = tradePeriod.split(separator: "Q")
        guard parts.count == 2,
              let year = parts.first,
              let q = parts.last else { return tradePeriod }
        return "\(year)年 第\(q)四半期"
    }

    /// 万円表記の価格（例: "7,800万円"）
    var formattedPrice: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let str = formatter.string(from: NSNumber(value: priceMan)) ?? "\(priceMan)"
        return "\(str)万円"
    }

    /// m² 単価の万円表記（例: "111.4万円/㎡"）
    var formattedM2Price: String {
        let man = Double(m2Price) / 10000.0
        return String(format: "%.1f万円/㎡", man)
    }
}

// MARK: - DTO（JSON デコード用）

struct TransactionRecordDTO: Codable {
    var id: String?
    var prefecture: String?
    var ward: String?
    var district: String?
    var district_code: String?
    var price_man: Int?
    var area_m2: Double?
    var m2_price: Int?
    var layout: String?
    var built_year: Int?
    var structure: String?
    var trade_period: String?
    var nearest_station: String?
    var estimated_walk_min: Int?
    var latitude: Double?
    var longitude: Double?
    var building_group_id: String?
    var estimated_building_name: String?
}

/// transactions.json のトップレベル構造
struct TransactionFeedDTO: Codable {
    var transactions: [TransactionRecordDTO]
    var building_groups: [BuildingGroupDTO]?
    var metadata: TransactionMetadataDTO?
}

struct BuildingGroupDTO: Codable {
    var group_id: String?
    var prefecture: String?
    var ward: String?
    var district: String?
    var built_year: Int?
    var structure: String?
    var nearest_station: String?
    var estimated_walk_min: Int?
    var latitude: Double?
    var longitude: Double?
    var transaction_count: Int?
    var price_range_man: [Int]?
    var avg_m2_price: Int?
    var periods: [String]?
    var latest_period: String?
    var estimated_building_name: String?
}

struct TransactionMetadataDTO: Codable {
    var updated_at: String?
    var periods_covered: [String]?
    var data_source: String?
    var transaction_count: Int?
    var building_group_count: Int?
    var scope: String?
}

// MARK: - DTO → Model 変換

extension TransactionRecord {
    static func from(dto: TransactionRecordDTO) -> TransactionRecord? {
        guard let id = dto.id,
              let prefecture = dto.prefecture,
              let ward = dto.ward,
              let district = dto.district,
              let priceMan = dto.price_man,
              let areaM2 = dto.area_m2,
              let m2Price = dto.m2_price,
              let layout = dto.layout,
              let builtYear = dto.built_year,
              let structure = dto.structure,
              let tradePeriod = dto.trade_period else {
            return nil
        }
        return TransactionRecord(
            txId: id,
            prefecture: prefecture,
            ward: ward,
            district: district,
            districtCode: dto.district_code ?? "",
            priceMan: priceMan,
            areaM2: areaM2,
            m2Price: m2Price,
            layout: layout,
            builtYear: builtYear,
            structure: structure,
            tradePeriod: tradePeriod,
            nearestStation: dto.nearest_station,
            estimatedWalkMin: dto.estimated_walk_min,
            latitude: dto.latitude,
            longitude: dto.longitude,
            buildingGroupId: dto.building_group_id,
            estimatedBuildingName: dto.estimated_building_name
        )
    }
}
