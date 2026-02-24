//
//  Listing.swift
//  RealEstateApp
//
//  scraping-tool/results/latest.json / latest_shinchiku.json の1件と対応するモデル
//

import Foundation
import SwiftData

@Model
final class Listing: @unchecked Sendable {
    var source: String?
    var url: String
    var name: String
    var priceMan: Int?
    var address: String?
    /// 住まいサーフィンから取得した番地レベルの詳細住所（パイプライン側で付与）
    var ssAddress: String?
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
    /// 管理費（円/月。SUUMO/HOME'S 詳細ページから取得）
    var managementFee: Int?
    /// 修繕積立金（円/月。SUUMO/HOME'S 詳細ページから取得）
    var repairReserveFund: Int?
    /// 向き（方角。例: "南", "北西"）
    var direction: String?
    /// バルコニー面積（㎡）
    var balconyAreaM2: Double?
    /// 駐車場（例: "空有 月額20,000円〜25,000円"）
    var parking: String?
    /// 施工会社（例: "大林組"）
    var constructor: String?
    /// 用途地域（例: "商業地域"）
    var zoning: String?
    /// 修繕積立基金（円。一時金。SUUMO 詳細ページから取得）
    var repairFundOnetime: Int?
    /// 特徴タグ（JSON 文字列。SUUMO の gapSuumoPcForKr から取得）
    /// フォーマット: ["駅徒歩5分以内","2沿線以上利用可",...]
    var featureTagsJSON: String?
    var listWardRoman: String?
    var fetchedAt: Date

    /// このリストに初めて追加された日時（同期では上書きしない）
    var addedAt: Date

    /// （レガシー）旧メモ。コメント機能に移行済み。
    var memo: String?
    /// いいね（同期では上書きしない）
    var isLiked: Bool
    /// コメント JSON 文字列（Firestore から同期、ローカルキャッシュ）
    /// フォーマット: [{"id":"...","text":"...","authorName":"...","authorId":"...","createdAt":"ISO8601"}]
    var commentsJSON: String?
    /// サイトから掲載が終了した（JSON から消えた）物件
    var isDelisted: Bool
    /// サーバーサイドで判定された新着物件フラグ（前回スクレイピングとの差分比較。Newバッジ表示用）
    var isNew: Bool

    /// 内見写真メタデータ JSON 文字列（ローカル保存）
    /// フォーマット: [{"id":"...","fileName":"...","createdAt":"ISO8601"}]
    var photosJSON: String?

    /// 間取り図画像 URL の JSON 文字列（スクレイピングツールから取得）
    /// フォーマット: ["https://...image1.jpg", "https://...image2.jpg"]
    var floorPlanImagesJSON: String?

    /// SUUMO 物件写真 JSON 文字列（スクレイピングツールから取得）
    /// フォーマット: [{"url":"https://...","label":"リビング"}, ...]
    var suumoImagesJSON: String?

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

    // MARK: - 重複集約

    /// 同一条件（物件名・間取り・価格）で検出された戸数（1 = ユニーク、2+ = 複数戸売出中）
    var duplicateCount: Int

    // MARK: - 住まいサーフィン評価データ

    /// 住まいサーフィン検索ステータス ("found" / "not_found" / "no_data")
    /// - found: 住まいサーフィンで発見し、データ取得済み
    /// - not_found: 住まいサーフィンで検索したが、該当物件が見つからなかった
    /// - no_data: 住まいサーフィンで該当ページは見つかったが、評価データがなかった
    /// - nil: 未検索（パイプライン未実行）
    var ssLookupStatus: String?

    /// 沖式儲かる確率 (%)
    var ssProfitPct: Int?
    /// 沖式中古時価 (万円, 70m²換算) — 中古のみ
    var ssOkiPrice70m2: Int?
    /// m²割安額 (万円/m²) — 新築のみ。負値=割安、正値=割高
    var ssM2Discount: Int?
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

    /// レーダーチャート偏差値 JSON 文字列（住まいサーフィン由来）
    /// 例: {"oki_price_m2":65.3,"build_age":52.1,"favorites":58.2,"walk_min":55.4,"appreciation_rate":62.8,"total_units":48.0}
    var ssRadarData: String?

    // MARK: - ハザード情報
    /// ハザード情報 JSON 文字列
    /// 例: {"flood":true,"sediment":false,"storm_surge":true,"tsunami":false,
    ///       "liquefaction":true,"inland_water":false,"building_collapse":3,"fire":2,"combined":3}
    var hazardInfo: String?

    // MARK: - 通勤時間
    /// 通勤時間情報 JSON 文字列（MKDirections で計算、ローカルキャッシュ）
    /// フォーマット: {"playground":{"minutes":25,"summary":"東京メトロ半蔵門線→半蔵門駅","calculatedAt":"ISO8601"},
    ///              "m3career":{"minutes":30,"summary":"東京メトロ日比谷線→虎ノ門ヒルズ駅","calculatedAt":"ISO8601"}}
    var commuteInfoJSON: String?

    // MARK: - 不動産情報ライブラリ（MLIT）相場データ
    /// 不動産情報ライブラリの成約価格相場データ JSON 文字列
    /// フォーマット: {"ward":"千代田区","ward_median_m2_price":1285000,"price_ratio":1.08,
    ///              "price_diff_man":620,"sample_count":42,"trend":"up","yoy_change_pct":3.2,
    ///              "quarterly_m2_prices":[{"quarter":"2024Q1","median_m2_price":980000,"count":30},...],
    ///              "data_source":"不動産情報ライブラリ（国土交通省）"}
    var reinfolibMarketData: String?

    // MARK: - e-Stat 人口動態データ
    /// e-Stat（総務省統計局）の人口・世帯数データ JSON 文字列
    /// フォーマット: {"ward":"江東区","latest_population":528950,"latest_households":287840,
    ///              "pop_change_1yr_pct":1.5,"pop_change_5yr_pct":7.8,
    ///              "population_history":[{"year":"2020","population":524310},...],
    ///              "household_history":[{"year":"2020","households":271500},...],
    ///              "data_source":"e-Stat（総務省統計局）"}
    var estatPopulationData: String?

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

    /// ローン残高 5年後（万円）
    var ssLoanBalance5yr: Int?
    /// ローン残高 10年後（万円）
    var ssLoanBalance10yr: Int?

    /// シミュレーション基準価格（万円）— サイト側が使用したデフォルト価格
    var ssSimBasePrice: Int?

    /// 新築時m²単価（万円）— 新築のみ
    var ssNewM2Price: Int?
    /// 10年後予測m²単価（万円）— 新築のみ
    var ssForecastM2Price: Int?
    /// 予測変動率 (%) — 新築のみ
    var ssForecastChangeRate: Double?

    /// 過去の相場推移 JSON 文字列
    /// フォーマット: [{"period":"2022年～","price_man":11021,"area_m2":70.2,"unit_price_man":157},...]
    var ssPastMarketTrends: String?

    /// 周辺の中古マンション相場 JSON 文字列
    /// フォーマット: [{"name":"サンクタス大森ヴァッサーハウス","appreciation_rate":79.2,"oki_price_70m2":7700,"url":"https://..."},...]
    var ssSurroundingProperties: String?

    /// 販売価格割安判定 JSON 文字列（中古のみ・ブラウザ自動化で取得）
    /// フォーマット: [{"unit":"3階/14階建","price_man":5980,"m2_price":78,"layout":"2LDK","area_m2":76.24,"direction":"南","oki_price_man":6200,"difference_man":-220,"judgment":"割安"},...]
    var ssPriceJudgments: String?

    init(
        source: String? = nil,
        url: String,
        name: String,
        priceMan: Int? = nil,
        address: String? = nil,
        ssAddress: String? = nil,
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
        managementFee: Int? = nil,
        repairReserveFund: Int? = nil,
        direction: String? = nil,
        balconyAreaM2: Double? = nil,
        parking: String? = nil,
        constructor: String? = nil,
        zoning: String? = nil,
        repairFundOnetime: Int? = nil,
        featureTagsJSON: String? = nil,
        listWardRoman: String? = nil,
        floorPlanImagesJSON: String? = nil,
        suumoImagesJSON: String? = nil,
        fetchedAt: Date = .now,
        addedAt: Date = .now,
        memo: String? = nil,
        isLiked: Bool = false,
        isDelisted: Bool = false,
        isNew: Bool = false,
        propertyType: String = "chuko",
        duplicateCount: Int = 1,
        priceMaxMan: Int? = nil,
        areaMaxM2: Double? = nil,
        deliveryDate: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        hazardInfo: String? = nil,
        commuteInfoJSON: String? = nil,
        ssLookupStatus: String? = nil,
        ssProfitPct: Int? = nil,
        ssOkiPrice70m2: Int? = nil,
        ssM2Discount: Int? = nil,
        ssValueJudgment: String? = nil,
        ssStationRank: String? = nil,
        ssWardRank: String? = nil,
        ssSumaiSurfinURL: String? = nil,
        ssAppreciationRate: Double? = nil,
        ssFavoriteCount: Int? = nil,
        ssPurchaseJudgment: String? = nil,
        ssRadarData: String? = nil,
        ssSimBest5yr: Int? = nil,
        ssSimBest10yr: Int? = nil,
        ssSimStandard5yr: Int? = nil,
        ssSimStandard10yr: Int? = nil,
        ssSimWorst5yr: Int? = nil,
        ssSimWorst10yr: Int? = nil,
        ssLoanBalance5yr: Int? = nil,
        ssLoanBalance10yr: Int? = nil,
        ssSimBasePrice: Int? = nil,
        ssNewM2Price: Int? = nil,
        ssForecastM2Price: Int? = nil,
        ssForecastChangeRate: Double? = nil,
        ssPastMarketTrends: String? = nil,
        ssSurroundingProperties: String? = nil,
        ssPriceJudgments: String? = nil,
        reinfolibMarketData: String? = nil,
        estatPopulationData: String? = nil
    ) {
        self.source = source
        self.url = url
        self.name = name
        self.priceMan = priceMan
        self.address = address
        self.ssAddress = ssAddress
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
        self.managementFee = managementFee
        self.repairReserveFund = repairReserveFund
        self.direction = direction
        self.balconyAreaM2 = balconyAreaM2
        self.parking = parking
        self.constructor = constructor
        self.zoning = zoning
        self.repairFundOnetime = repairFundOnetime
        self.featureTagsJSON = featureTagsJSON
        self.listWardRoman = listWardRoman
        self.floorPlanImagesJSON = floorPlanImagesJSON
        self.suumoImagesJSON = suumoImagesJSON
        self.fetchedAt = fetchedAt
        self.addedAt = addedAt
        self.memo = memo
        self.isLiked = isLiked
        self.isDelisted = isDelisted
        self.isNew = isNew
        self.propertyType = propertyType
        self.duplicateCount = duplicateCount
        self.priceMaxMan = priceMaxMan
        self.areaMaxM2 = areaMaxM2
        self.deliveryDate = deliveryDate
        self.latitude = latitude
        self.longitude = longitude
        self.hazardInfo = hazardInfo
        self.commuteInfoJSON = commuteInfoJSON
        self.ssLookupStatus = ssLookupStatus
        self.ssProfitPct = ssProfitPct
        self.ssOkiPrice70m2 = ssOkiPrice70m2
        self.ssM2Discount = ssM2Discount
        self.ssValueJudgment = ssValueJudgment
        self.ssStationRank = ssStationRank
        self.ssWardRank = ssWardRank
        self.ssSumaiSurfinURL = ssSumaiSurfinURL
        self.ssAppreciationRate = ssAppreciationRate
        self.ssFavoriteCount = ssFavoriteCount
        self.ssPurchaseJudgment = ssPurchaseJudgment
        self.ssRadarData = ssRadarData
        self.ssSimBest5yr = ssSimBest5yr
        self.ssSimBest10yr = ssSimBest10yr
        self.ssSimStandard5yr = ssSimStandard5yr
        self.ssSimStandard10yr = ssSimStandard10yr
        self.ssSimWorst5yr = ssSimWorst5yr
        self.ssSimWorst10yr = ssSimWorst10yr
        self.ssLoanBalance5yr = ssLoanBalance5yr
        self.ssLoanBalance10yr = ssLoanBalance10yr
        self.ssSimBasePrice = ssSimBasePrice
        self.ssNewM2Price = ssNewM2Price
        self.ssForecastM2Price = ssForecastM2Price
        self.ssForecastChangeRate = ssForecastChangeRate
        self.ssPastMarketTrends = ssPastMarketTrends
        self.ssSurroundingProperties = ssSurroundingProperties
        self.ssPriceJudgments = ssPriceJudgments
        self.reinfolibMarketData = reinfolibMarketData
        self.estatPopulationData = estatPopulationData
    }

    // MARK: - Identity

    /// 同一物件判定用（report_utils.identity_key と同一フィールド・同一順序）。
    /// 価格・walk_min・total_units は重複集約の代表レコード変更で変動するため含めない。
    /// station_line は駅名のみ抽出して表記揺れを吸収。
    var identityKey: String {
        [
            Self.cleanListingName(name)
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression),
            (layout ?? "").trimmingCharacters(in: .whitespaces),
            areaM2.map { "\($0)" } ?? "",
            (address ?? "").trimmingCharacters(in: .whitespaces),
            builtYear.map { "\($0)" } ?? "",
            Self.extractStationName(from: stationLine ?? "")
        ].joined(separator: "|")
    }

    /// station_line から駅名のみを抽出する（report_utils._extract_station_name 相当）。
    /// 例: "ＪＲ総武線（秋葉原～千葉）「錦糸町」徒歩5分" → "錦糸町"
    static func extractStationName(from stationLine: String) -> String {
        guard !stationLine.isEmpty,
              let match = stationLine.range(of: #"[「『]([^」』]+)[」』]"#, options: .regularExpression) else {
            return ""
        }
        let inner = stationLine[match]
        return String(inner.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    var isShinchiku: Bool { propertyType == "shinchiku" }

    /// 複数戸が同一条件で売り出されているか
    var hasMultipleUnits: Bool { duplicateCount > 1 }

    /// 表示用: 複数戸売出バッジテキスト（例: "2戸売出中"）
    var duplicateCountDisplay: String? {
        guard duplicateCount > 1 else { return nil }
        return "\(duplicateCount)戸売出中"
    }

    // MARK: - マンション単位グルーピング

    /// 同一マンション判定用キー。
    /// 一覧画面で同一マンション内の複数住戸をグルーピングして展開表示するために使用。
    ///
    /// マスト条件（4項目）:
    /// 1. cleanListingName（空白除去）― 建物名
    /// 2. normalizedAddress（丁目レベル）― 所在地
    /// 3. floorTotal ― 何階建て（同一敷地内の別棟を区別）
    /// 4. ownership ― 権利形態
    ///
    /// 除外した項目と理由:
    /// - walkMin: SUUMOページごとに異なる最寄駅が記載されるため不一致が生じる
    /// - totalUnits: SUUMOのデータ不整合が多い（864/255/866等）
    /// - builtYear: まれにデータ不整合あり（2008/2009等）
    /// - 価格・間取り・面積・階数: 住戸ごとに異なる
    var buildingGroupKey: String {
        // キャッシュ無効化: name + address + floorTotal + ownership を結合してソースキーとする
        let sourceKey = "\(name)|\(address ?? "")|\(floorTotal ?? -1)|\(ownership ?? "")"
        if let cached = _cachedBuildingGroupKey, _cachedBuildingGroupKeySource == sourceKey {
            return cached
        }
        let cleanName = Self.cleanListingName(name)
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let normalizedAddr = Self.normalizeAddressForGrouping(address ?? "")
        let key = [
            cleanName,
            normalizedAddr,
            floorTotal.map(String.init) ?? "",
            (ownership ?? "").trimmingCharacters(in: .whitespaces)
        ].joined(separator: "|")
        _cachedBuildingGroupKey = key
        _cachedBuildingGroupKeySource = sourceKey
        return key
    }

    /// 住所を丁目レベルに正規化する（番・号を除去）。
    /// 同一マンションでもSUUMO掲載により `若葉３` と `若葉３－２` のように
    /// 番地以下の精度が異なるケースがあるため、最初の数字ブロックまでを使用。
    ///
    /// 例:
    /// - `東京都北区王子５-1-2` → `東京都北区王子5`
    /// - `東京都新宿区若葉３－２` → `東京都新宿区若葉3`
    /// - `東京都墨田区江東橋２－９－１` → `東京都墨田区江東橋2`
    static func normalizeAddressForGrouping(_ addr: String) -> String {
        var s = addr.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespaces)
        // 最初の数字ブロックの後のセパレータ（-／ー／－）以降を除去
        s = s.replacingOccurrences(
            of: #"(\d+)\s*[ー－\-/／].*$"#,
            with: "$1",
            options: .regularExpression
        )
        return s
    }

    // MARK: - Display Properties

    // MARK: - 価格フォーマット

    /// 万円の数値をカンマ区切り ＋ 億変換で表示文字列にする
    /// - Parameter man: 万円の値
    /// - Parameter suffix: 末尾に付ける文字列（"万円" / "万" など）
    /// - Returns: 例: 9800 → "9,800万", 12000 → "1.2億"
    private static let priceFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private static func formatPriceMan(_ man: Int, unit: String = "万") -> String {
        if man >= 10000 {
            let oku = Double(man) / 10000.0
            // 整数なら小数点なし（"2億"）、そうでなければ小数1桁（"1.2億"）
            if oku == oku.rounded(.down) && oku.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(oku))億"
            }
            return String(format: "%.1f億", oku)
        }
        let formatted = priceFormatter.string(from: NSNumber(value: man)) ?? "\(man)"
        return "\(formatted)\(unit)"
    }

    /// 表示用: 価格（万円）— 新築は帯表示対応（詳細画面用: 万円 付き）
    var priceDisplay: String {
        if let lo = priceMan {
            if let hi = priceMaxMan, hi != lo {
                return "\(Self.formatPriceMan(lo, unit: "万"))〜\(Self.formatPriceMan(hi, unit: "万円"))"
            }
            return Self.formatPriceMan(lo, unit: "万円")
        }
        return isShinchiku ? "価格未定" : "—"
    }

    /// 表示用: 価格コンパクト（一覧カード用: 円 なし）
    /// HTML デザイン準拠: "9,800万", "6,000万〜1.2億"
    var priceDisplayCompact: String {
        if let lo = priceMan {
            if let hi = priceMaxMan, hi != lo {
                return "\(Self.formatPriceMan(lo))〜\(Self.formatPriceMan(hi))"
            }
            return Self.formatPriceMan(lo)
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

    /// 平米単価（万円/㎡）。価格と面積の両方が必要
    var m2UnitPrice: Double? {
        guard let price = priceMan, let area = areaM2, area > 0 else { return nil }
        return Double(price) / area
    }

    /// 坪単価（万円/坪）。1坪 = 3.30578㎡
    var tsuboUnitPrice: Double? {
        guard let m2Price = m2UnitPrice else { return nil }
        return m2Price * 3.30578
    }

    /// 表示用: 平米単価
    var m2UnitPriceDisplay: String {
        guard let price = m2UnitPrice else { return "—" }
        return String(format: "%.1f万円/㎡", price)
    }

    /// 表示用: 坪単価
    var tsuboUnitPriceDisplay: String {
        guard let price = tsuboUnitPrice else { return "—" }
        return String(format: "%.1f万円/坪", price)
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

    // MARK: - メイン路線名置換

    /// 複数路線が乗り入れる駅で、利用者数が最多のメイン路線名マッピング。
    /// スクレイピングデータでマイナー路線名が入った場合にメイン路線名に置換して表示する。
    /// キー: 駅名、値: 利用者数が最も多い代表路線名
    static let preferredLineForStation: [String: String] = [
        // --- ゆりかもめ沿線（他にメジャー路線がある駅） ---
        "新橋": "ＪＲ山手線",
        "汐留": "都営大江戸線",
        "豊洲": "東京メトロ有楽町線",
        "有明": "りんかい線",
        // --- りんかい線沿線 ---
        "大井町": "ＪＲ京浜東北線",
        "大崎": "ＪＲ山手線",
        // --- つくばエクスプレス沿線 ---
        "秋葉原": "ＪＲ山手線",
        "北千住": "東京メトロ日比谷線",
        "南千住": "ＪＲ常磐線",
        "浅草": "東京メトロ銀座線",
        // --- 東京モノレール沿線 ---
        "浜松町": "ＪＲ山手線",
        // --- 日暮里・舎人ライナー沿線 ---
        "日暮里": "ＪＲ山手線",
        "西日暮里": "東京メトロ千代田線",
        // --- 都電荒川線沿線 ---
        "王子": "ＪＲ京浜東北線",
        "大塚": "ＪＲ山手線",
        "町屋": "東京メトロ千代田線",
        // --- 主要ターミナル（JR山手線がメイン） ---
        "東京": "ＪＲ山手線",
        "品川": "ＪＲ山手線",
        "渋谷": "ＪＲ山手線",
        "新宿": "ＪＲ山手線",
        "池袋": "ＪＲ山手線",
        "上野": "ＪＲ山手線",
        "目黒": "ＪＲ山手線",
        "恵比寿": "ＪＲ山手線",
        "五反田": "ＪＲ山手線",
        "田町": "ＪＲ山手線",
        "高田馬場": "ＪＲ山手線",
        "目白": "ＪＲ山手線",
        "巣鴨": "ＪＲ山手線",
        "駒込": "ＪＲ山手線",
        "代々木": "ＪＲ山手線",
        "原宿": "ＪＲ山手線",
        "神田": "ＪＲ山手線",
        "有楽町": "ＪＲ山手線",
        "御徒町": "ＪＲ山手線",
        // --- メトロ・都営の主要乗換駅 ---
        "飯田橋": "東京メトロ東西線",
        "市ヶ谷": "東京メトロ有楽町線",
        "四ツ谷": "東京メトロ丸ノ内線",
        "御茶ノ水": "東京メトロ丸ノ内線",
        "大手町": "東京メトロ丸ノ内線",
        "霞ケ関": "東京メトロ丸ノ内線",
        "表参道": "東京メトロ銀座線",
        "六本木": "東京メトロ日比谷線",
        "月島": "東京メトロ有楽町線",
        "後楽園": "東京メトロ丸ノ内線",
        "銀座": "東京メトロ銀座線",
        "日本橋": "東京メトロ銀座線",
        "九段下": "東京メトロ東西線",
        "門前仲町": "東京メトロ東西線",
        "清澄白河": "東京メトロ半蔵門線",
        "住吉": "東京メトロ半蔵門線",
        "押上": "東京メトロ半蔵門線",
        "錦糸町": "ＪＲ総武線",
        "両国": "ＪＲ総武線",
        "亀戸": "ＪＲ総武線",
        "中目黒": "東京メトロ日比谷線",
        "春日": "都営三田線",
    ]

    /// 路線名テキストの1セグメントをメイン路線名に置換する。
    /// 例: "ゆりかもめ「豊洲」徒歩4分" → "東京メトロ有楽町線「豊洲」徒歩4分"
    static func replaceWithPreferredLine(_ text: String) -> String {
        guard let start = text.firstIndex(of: "「"),
              let end = text.firstIndex(of: "」"),
              start < end else { return text }
        let stName = String(text[text.index(after: start)..<end])
        guard let preferred = preferredLineForStation[stName] else { return text }
        let currentLine = String(text[text.startIndex..<start])
        if currentLine == preferred { return text }
        return preferred + String(text[start...])
    }

    /// 表示用: stationLine のメイン路線名置換版。
    /// 複数路線が乗り入れる駅で、マイナー路線名がデータに入っている場合に
    /// 利用者数が多いメイン路線名に置換して表示する。
    var displayStationLine: String? {
        guard let line = stationLine, !line.isEmpty else { return stationLine }
        let segments = line.components(separatedBy: CharacterSet(charactersIn: "／/"))
        let replaced = segments.map { Self.replaceWithPreferredLine($0.trimmingCharacters(in: .whitespaces)) }
        return replaced.joined(separator: "／")
    }

    // MARK: - Station Parsing

    /// stationLine から全駅情報をパース（複数駅対応）
    /// 例: "ＪＲ山手線「目白」徒歩4分／東京メトロ副都心線「雑司が谷」徒歩8分"
    ///   → [("ＪＲ山手線「目白」徒歩4分", "目白", 4), ("東京メトロ副都心線「雑司が谷」徒歩8分", "雑司が谷", 8)]
    struct StationInfo: Identifiable {
        let id = UUID()
        let fullText: String     // "路線名「駅名」徒歩X分"
        let routeName: String    // "ＪＲ山手線" 等
        let stationName: String  // "駅名"
        let walkMin: Int?        // 徒歩分数
    }

    var parsedStations: [StationInfo] {
        guard let line = stationLine, !line.isEmpty else { return [] }
        // ／ or / で分割
        let segments = line.components(separatedBy: CharacterSet(charactersIn: "／/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result: [StationInfo] = []
        var pendingRoute: String?

        for seg in segments {
            // 路線名・駅名抽出（「」括弧あり）
            var route = ""
            var name = seg
            var hasBrackets = false
            if let s = seg.firstIndex(of: "「"), let e = seg.firstIndex(of: "」"), s < e {
                route = String(seg[seg.startIndex..<s]).trimmingCharacters(in: .whitespaces)
                name = String(seg[seg.index(after: s)..<e])
                hasBrackets = true
            }
            // 徒歩分数抽出
            var walk: Int? = nil
            if let range = seg.range(of: #"徒歩\s*約?\s*(\d+)\s*分"#, options: .regularExpression) {
                let matched = seg[range]
                if let numRange = matched.range(of: #"\d+"#, options: .regularExpression) {
                    walk = Int(matched[numRange])
                }
            }

            // 括弧も徒歩もない & 路線名らしい → 次セグメントとマージ用に保持
            let isRouteOnly = !hasBrackets && walk == nil
                && (seg.contains("線") || seg.hasSuffix("ライン"))
            if isRouteOnly {
                if let existing = pendingRoute {
                    result.append(StationInfo(fullText: existing, routeName: existing, stationName: "", walkMin: nil))
                }
                pendingRoute = seg
                continue
            }

            // 括弧なしの場合、駅名から徒歩部分を除去
            if !hasBrackets {
                name = seg.replacingOccurrences(of: #"[\s　]*徒歩\s*約?\s*\d+\s*分.*$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if name.isEmpty { name = seg }
            }

            // 保留中の路線名があればマージ
            if let pending = pendingRoute {
                if route.isEmpty { route = pending }
                result.append(StationInfo(
                    fullText: "\(pending) \(seg)",
                    routeName: route,
                    stationName: name,
                    walkMin: walk
                ))
                pendingRoute = nil
            } else {
                result.append(StationInfo(fullText: seg, routeName: route, stationName: name, walkMin: walk))
            }
        }

        // 末尾に路線名だけ残った場合
        if let pending = pendingRoute {
            result.append(StationInfo(fullText: pending, routeName: pending, stationName: "", walkMin: nil))
        }

        return result
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

    /// 表示用: 階数（○階/○階建）。データなしは空文字を返す
    var floorDisplay: String {
        let pos = floorPosition.map { "\($0)階" }
        let total = floorTotal.map { "\($0)階建" }
        switch (pos, total) {
        case let (p?, t?): return "\(p)/\(t)"
        case let (p?, nil): return p
        case let (nil, t?): return t
        case (nil, nil): return ""
        }
    }

    /// 表示用: 階建のみ（新築一覧用。何階建かだけ表示）
    var floorTotalDisplay: String {
        floorTotal.map { "\($0)階建" } ?? "—"
    }

    /// 権利形態の種別
    enum OwnershipType {
        case owned       // 所有権
        case leasehold   // 定期借地権・借地権
        case unknown     // 不明
    }

    /// 権利形態の種別を判定
    var ownershipType: OwnershipType {
        guard let o = ownership, !o.isEmpty else { return .unknown }
        if o.contains("所有権") { return .owned }
        if o.contains("借地") { return .leasehold }
        return .unknown
    }

    /// 表示用: 権利形態（短縮: 所有権 or 定借）
    var ownershipShort: String {
        guard let o = ownership, !o.isEmpty else { return "—" }
        if o.contains("所有権") { return "所有権" }
        if o.contains("借地") { return "定借" }
        return String(o.prefix(4))
    }

    /// 表示用: 権利形態 SF Symbol 名
    var ownershipIconName: String {
        switch ownershipType {
        case .owned: return "shield.checkered"
        case .leasehold: return "clock.arrow.circlepath"
        case .unknown: return ""
        }
    }

    /// 表示用: 総戸数
    var totalUnitsDisplay: String {
        guard let u = totalUnits else { return "—" }
        return "\(u)戸"
    }

    /// 表示用: 向き
    var directionDisplay: String {
        direction ?? "—"
    }

    /// 表示用: バルコニー面積
    var balconyAreaDisplay: String {
        guard let area = balconyAreaM2 else { return "—" }
        return String(format: "%.2f㎡", area)
    }

    /// 表示用: 修繕積立基金（一時金）
    var repairFundOnetimeDisplay: String {
        guard let val = repairFundOnetime else { return "—" }
        let man = Double(val) / 10000.0
        if man >= 1.0 {
            return String(format: "%.1f万円", man)
        }
        return "\(val.formatted())円"
    }

    /// featureTagsJSON をパースして文字列配列で返す
    var parsedFeatureTags: [String] {
        guard let json = featureTagsJSON,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr
    }

    /// 特徴タグがあるか
    var hasFeatureTags: Bool {
        featureTagsJSON != nil && !parsedFeatureTags.isEmpty
    }

    /// 表示用: 追加日（static DateFormatter で毎回のアロケーションを回避）
    private static let addedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d"
        return f
    }()

    var addedAtDisplay: String {
        Self.addedAtFormatter.string(from: addedAt)
    }

    // isNew は stored property として定義済み（前回の同期時に存在しなかった新着物件フラグ）

    /// 住まいサーフィンの詳細住所（ss_address）があればそちらを優先、なければ元の住所
    var bestAddress: String? {
        if let ss = ssAddress, !ss.isEmpty { return ss }
        return address
    }

    /// ジオコーディング済みかどうか
    var hasCoordinate: Bool {
        latitude != nil && longitude != nil
    }

    /// 住まいサーフィンのデータがあるかどうか
    var hasSumaiSurfinData: Bool {
        ssProfitPct != nil || ssOkiPrice70m2 != nil || ssM2Discount != nil
            || computedPriceJudgment != nil || ssAppreciationRate != nil
            || ssFavoriteCount != nil || ssSimBest5yr != nil
    }

    // MARK: - JSON パースキャッシュ（@Transient = SwiftData 非永続化）
    // 各 JSON 文字列のパース結果をメモリ内にキャッシュし、body 再評価のたびにデコードが走るのを防ぐ。
    // ソース JSON が変わった場合は自動的にキャッシュを無効化する。

    @Transient private var _cache = ListingJSONCache()
    @Transient private var _cachedBuildingGroupKey: String?
    @Transient private var _cachedBuildingGroupKeySource: String?

    /// JSON パース結果のインメモリキャッシュ。Listing ごとに1つ保持。
    private class ListingJSONCache {
        var comments: (source: String?, result: [CommentData])?
        var photos: (source: String?, result: [PhotoMeta])?
        var commuteInfo: (source: String?, result: CommuteData)?
        var radarData: (source: String?, result: RadarData?)?
        var surrounding: (source: String?, result: [SurroundingProperty])?
        var priceJudgments: (source: String?, result: [PriceJudgmentUnit])?
        var hazard: (source: String?, result: HazardData)?
        var marketData: (source: String?, result: MarketData?)?
        var populationData: (source: String?, result: PopulationData?)?
        var marketTrends: (source: String?, result: [MarketTrendEntry])?
        var suumoImages: (source: String?, result: [SuumoImage])?
        var floorPlanImages: (source: String?, result: [URL])?
    }

    // MARK: - 周辺物件データ

    /// 周辺の中古マンション相場の1件
    struct SurroundingProperty: Identifiable {
        let id = UUID()
        let name: String
        let appreciationRate: Double?  // 中古値上がり率 (%)
        let okiPrice70m2: Int?         // 沖式中古時価 70m²換算 (万円)
        let url: String?               // 住まいサーフィンURL
    }

    /// ssSurroundingProperties JSON をパースして配列で返す（キャッシュ付き）
    var parsedSurroundingProperties: [SurroundingProperty] {
        if let cached = _cache.surrounding, cached.source == ssSurroundingProperties {
            return cached.result
        }
        let result = Self._parseSurroundingProperties(ssSurroundingProperties)
        _cache.surrounding = (ssSurroundingProperties, result)
        return result
    }

    private static func _parseSurroundingProperties(_ json: String?) -> [SurroundingProperty] {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let rate = dict["appreciation_rate"] as? Double
            let price = dict["oki_price_70m2"] as? Int
            let url = dict["url"] as? String
            return SurroundingProperty(name: name, appreciationRate: rate, okiPrice70m2: price, url: url)
        }
    }

    /// 周辺物件データがあるか
    var hasSurroundingProperties: Bool {
        ssSurroundingProperties != nil && !parsedSurroundingProperties.isEmpty
    }

    // MARK: - 販売価格割安判定（中古のみ）

    /// 販売住戸ごとの割安/割高判定
    struct PriceJudgmentUnit: Identifiable {
        let id = UUID()
        let unit: String?           // "3階/14階建"
        let priceMan: Int?          // 販売価格（万円）
        let m2Price: Int?           // m²単価（万円）
        let layout: String?         // 間取り
        let areaM2: Double?         // 面積（㎡）
        let direction: String?      // 向き
        let okiPriceMan: Int?       // 沖式中古時価（万円）
        let differenceMan: Int?     // 差額（万円、マイナス=割安）
        let judgment: String?       // "割安" / "割高" / "適正"
    }

    /// ssPriceJudgments JSON をパースして配列で返す（キャッシュ付き）
    var parsedPriceJudgments: [PriceJudgmentUnit] {
        if let cached = _cache.priceJudgments, cached.source == ssPriceJudgments {
            return cached.result
        }
        let result = Self._parsePriceJudgments(ssPriceJudgments)
        _cache.priceJudgments = (ssPriceJudgments, result)
        return result
    }

    private static func _parsePriceJudgments(_ json: String?) -> [PriceJudgmentUnit] {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { dict in
            PriceJudgmentUnit(
                unit: dict["unit"] as? String,
                priceMan: dict["price_man"] as? Int,
                m2Price: dict["m2_price"] as? Int,
                layout: dict["layout"] as? String,
                areaM2: dict["area_m2"] as? Double,
                direction: dict["direction"] as? String,
                okiPriceMan: dict["oki_price_man"] as? Int,
                differenceMan: dict["difference_man"] as? Int,
                judgment: dict["judgment"] as? String
            )
        }
    }

    /// 割安判定データがあるか
    var hasPriceJudgments: Bool {
        ssPriceJudgments != nil && !parsedPriceJudgments.isEmpty
    }

    // MARK: - レーダーチャートデータ

    /// レーダーチャートの6軸データ（偏差値ベース、0-100）
    /// 軸の順番・ラベルは住まいサーフィンのサイト表示に準拠
    struct RadarData {
        var okiPriceM2: Double       // 沖式中古時価m²単価
        var buildAge: Double         // 築年数
        var favorites: Double        // お気に入り数
        var walkMin: Double          // 徒歩分数
        var appreciationRate: Double // 中古値上がり率
        var totalUnits: Double       // 総戸数

        /// 6軸を配列で返す（描画用 — サイトと同じ時計回り順）
        var values: [Double] { [okiPriceM2, buildAge, favorites, walkMin, appreciationRate, totalUnits] }

        /// 軸ラベル（サイト準拠）
        static let labels = ["沖式中古時価\nm²単価", "築年数", "お気に入り数", "徒歩分数", "中古値上がり率", "総戸数"]

        /// 軸ラベル（1行版 — テーブル表示用）
        static let labelsSingleLine = ["沖式時価m²単価", "築年数", "お気に入り数", "徒歩分数", "中古値上がり率", "総戸数"]

        /// 6軸の平均偏差値
        var average: Double {
            values.reduce(0, +) / Double(values.count)
        }
    }

    /// ssRadarData JSON をパースしてレーダーチャートデータを返す（キャッシュ付き）。
    /// 対応形式:
    ///   1. named-key 形式: {"oki_price_m2":65.3, "build_age":58.2, ...}
    ///   2. labels/values 形式 (旧): {"labels":["沖式中古時価m²単価",...], "values":[65.3,...]}
    /// JSON がない場合は既存フィールドからフォールバック計算する。
    var parsedRadarData: RadarData? {
        // キャッシュヒット判定（ssRadarData + フォールバック入力が同じなら再利用）
        if let cached = _cache.radarData, cached.source == ssRadarData {
            return cached.result
        }
        let result = _parseRadarDataImpl()
        _cache.radarData = (ssRadarData, result)
        return result
    }

    private func _parseRadarDataImpl() -> RadarData? {
        // まず JSON パースを試行
        if let json = ssRadarData,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // labels/values 配列形式（旧 enricher 出力）を named-key に変換
            if let labels = dict["labels"] as? [String],
               let values = dict["values"] as? [Double] {
                let labelToKey: [String: String] = [
                    "沖式中古時価m²単価": "oki_price_m2",
                    "沖式時価m²単価": "oki_price_m2",
                    "沖式時価": "oki_price_m2",
                    "築年数": "build_age",
                    "お気に入り数": "favorites",
                    "お気に入り": "favorites",
                    "徒歩分数": "walk_min",
                    "中古値上がり率": "appreciation_rate",
                    "値上がり率": "appreciation_rate",
                    "総戸数": "total_units",
                    // 旧キー互換
                    "資産性": "appreciation_rate",
                    "アクセス数": "oki_price_m2",
                ]
                var mapped: [String: Double] = [:]
                for (i, label) in labels.enumerated() where i < values.count {
                    if let key = labelToKey[label] { mapped[key] = values[i] }
                }
                return RadarData(
                    okiPriceM2: mapped["oki_price_m2"] ?? 50,
                    buildAge: mapped["build_age"] ?? 50,
                    favorites: mapped["favorites"] ?? 50,
                    walkMin: mapped["walk_min"] ?? 50,
                    appreciationRate: mapped["appreciation_rate"] ?? 50,
                    totalUnits: mapped["total_units"] ?? 50
                )
            }

            // named-key 形式（新 enricher 出力）
            return RadarData(
                okiPriceM2: (dict["oki_price_m2"] as? Double) ?? 50,
                buildAge: (dict["build_age"] as? Double) ?? 50,
                favorites: (dict["favorites"] as? Double) ?? 50,
                walkMin: (dict["walk_min"] as? Double) ?? 50,
                appreciationRate: (dict["appreciation_rate"] as? Double) ?? 50,
                totalUnits: (dict["total_units"] as? Double) ?? 50
            )
        }

        // フォールバック: 既存データから推定（大まかな偏差値近似）
        guard hasSumaiSurfinData else { return nil }

        // 沖式時価: 有無で推定
        let okiVal: Double = ssOkiPrice70m2 != nil ? 55 : 50

        // 値上がり率 → 偏差値（0% = 50, ±10% = ±10）
        let rateVal: Double = {
            guard let rate = ssAppreciationRate else { return 50 }
            return min(80, max(20, 50 + rate))
        }()

        // お気に入りカウント → 偏差値
        let favVal: Double = {
            guard let fav = ssFavoriteCount else { return 50 }
            return min(80, max(20, 50 + Double(fav) / 5.0))
        }()

        // 徒歩分数 → 偏差値（短いほど高い。5分=65, 10分=50, 15分=35）
        let walkVal: Double = {
            guard let walk = walkMin else { return 50 }
            return min(80, max(20, 65 - Double(walk - 5) * 3))
        }()

        return RadarData(
            okiPriceM2: okiVal,
            buildAge: 50,          // 築年数はフォールバック不可
            favorites: favVal,
            walkMin: walkVal,
            appreciationRate: rateVal,
            totalUnits: 50          // 総戸数はフォールバック不可
        )
    }

    /// 平均偏差値（レーダーチャート6軸の平均）。データなしは nil。
    var averageDeviation: Double? {
        parsedRadarData?.average
    }

    /// 平均偏差値の表示文字列（小数第1位まで）。データなしは "—"。
    var averageDeviationDisplay: String {
        guard let avg = averageDeviation else { return "—" }
        return String(format: "%.1f", avg)
    }

    // MARK: - 過去の相場推移

    /// 相場推移 1 エントリ
    struct MarketTrendEntry {
        let period: String     // "2022年～"
        let priceMan: Int      // 万円
        let areaM2: Double?    // ㎡
        let unitPriceMan: Int? // ㎡単価（万円）
    }

    /// ssPastMarketTrends JSON をパースして配列を返す（キャッシュ付き）
    var parsedMarketTrends: [MarketTrendEntry] {
        if let cached = _cache.marketTrends, cached.source == ssPastMarketTrends {
            return cached.result
        }
        let result = Self._parseMarketTrends(ssPastMarketTrends)
        _cache.marketTrends = (ssPastMarketTrends, result)
        return result
    }

    private static func _parseMarketTrends(_ json: String?) -> [MarketTrendEntry] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { dict in
            guard let period = dict["period"] as? String,
                  let price = dict["price_man"] as? Int else { return nil }
            return MarketTrendEntry(
                period: period,
                priceMan: price,
                areaM2: dict["area_m2"] as? Double,
                unitPriceMan: dict["unit_price_man"] as? Int
            )
        }
    }

    /// 過去の相場推移データがあるか
    var hasMarketTrends: Bool {
        ssPastMarketTrends != nil && !parsedMarketTrends.isEmpty
    }

    /// 値上がりシミュレーションデータがあるか（新築のみ）
    ///
    /// 以下のいずれかで計算可能:
    ///   1. シミュレーション絶対値（ベスト/標準/ワースト）がある → 変動率を逆算して使用
    ///   2. 予測変動率（ss_forecast_change_rate）がある → ±10pp スプレッドで推定
    var hasSimulationData: Bool {
        isShinchiku
            && (
                (ssSimBest5yr != nil && ssSimStandard5yr != nil && ssSimWorst5yr != nil)
                || ssForecastChangeRate != nil
            )
    }

    /// 10年後予測詳細データがあるか（新築のみ）
    var hasForecastDetail: Bool {
        isShinchiku
            && (ssNewM2Price != nil || ssForecastM2Price != nil || ssForecastChangeRate != nil || ssPurchaseJudgment != nil)
    }

    /// 表示用: 沖式儲かる確率
    var ssProfitDisplay: String {
        guard let pct = ssProfitPct else { return "—" }
        return "\(pct)%"
    }

    /// 表示用: 沖式時価（70m²換算）
    var ssOkiPriceDisplay: String {
        guard let price = ssOkiPrice70m2 else { return "—" }
        return "\(price)万円"
    }

    /// 沖式中古時価を実際の専有面積に換算した値（万円）
    /// 計算式: ssOkiPrice70m2 / 70 * areaM2
    var ssOkiPriceForArea: Int? {
        guard let price70 = ssOkiPrice70m2, let area = areaM2, area > 0 else { return nil }
        return Int(round(Double(price70) / 70.0 * area))
    }

    /// 表示用: 沖式時価（実面積換算）
    var ssOkiPriceForAreaDisplay: String {
        guard let price = ssOkiPriceForArea else { return "—" }
        return "\(price)万円"
    }

    /// 販売価格判定
    ///
    /// 住まいサーフィンが提供する判定ラベルをそのまま使用する。
    /// 独自の閾値による計算は行わない。
    ///
    /// 優先順位:
    ///   1. `ssValueJudgment` — ブラウザ自動化で取得した代表判定
    ///   2. `ssPriceJudgments` — 住戸ごとの判定から掲載価格に最も近い住戸を採用
    ///   3. データなし → nil
    var computedPriceJudgment: String? {
        // 1. ブラウザ自動化で設定済みならそれを使用
        if let j = ssValueJudgment, !j.isEmpty {
            return j
        }
        // 2. 住戸ごとの割安判定から掲載価格に最も近い住戸を採用
        if let j = bestMatchingPriceJudgment {
            return j
        }
        // 住まいサーフィンのデータがない場合は nil
        return nil
    }

    /// ssPriceJudgments の住戸から掲載価格に最も近い住戸の judgment を返す
    private var bestMatchingPriceJudgment: String? {
        let units = parsedPriceJudgments
        guard !units.isEmpty else { return nil }

        let withJudgment = units.filter { $0.judgment != nil && !($0.judgment?.isEmpty ?? true) }
        guard !withJudgment.isEmpty else { return nil }

        // 住戸が1つなら即採用
        if withJudgment.count == 1 {
            return withJudgment[0].judgment
        }

        // 掲載価格に最も近い住戸を探す
        if let listingPrice = priceMan {
            var best: PriceJudgmentUnit?
            var bestDiff = Int.max
            for unit in withJudgment {
                if let unitPrice = unit.priceMan {
                    let diff = abs(unitPrice - listingPrice)
                    if diff < bestDiff {
                        bestDiff = diff
                        best = unit
                    }
                }
            }
            if let best = best {
                return best.judgment
            }
        }

        // フォールバック: 最初の住戸
        return withJudgment[0].judgment
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

        /// 何らかの重大なハザードリスクがあるか（一覧バッジ表示用）
        var hasAnyHazard: Bool {
            flood || sediment || stormSurge || tsunami || liquefaction || inlandWater
                || buildingCollapse >= 3 || fire >= 3 || combined >= 3
        }

        /// ハザードデータが存在するか（詳細画面セクション表示用 — 低ランクでも表示）
        var hasAnyData: Bool {
            flood || sediment || stormSurge || tsunami || liquefaction || inlandWater
                || buildingCollapse > 0 || fire > 0 || combined > 0
        }

        /// 該当するハザード種別のラベル配列（一覧バッジ用 — 重大リスクのみ）
        var activeLabels: [(icon: String, label: String, severity: HazardSeverity)] {
            var results: [(String, String, HazardSeverity)] = []
            if flood { results.append(("drop.fill", "洪水浸水", .warning)) }
            if inlandWater { results.append(("drop.fill", "内水浸水", .warning)) }
            if sediment { results.append(("mountain.2.fill", "土砂災害", .danger)) }
            if stormSurge { results.append(("wind", "高潮浸水", .warning)) }
            if tsunami { results.append(("water.waves", "津波浸水", .danger)) }
            if liquefaction { results.append(("waveform.path.ecg", "液状化", .warning)) }
            // 東京都地域危険度: 建物倒壊・火災・総合を独立ラベルで表示
            if buildingCollapse >= 3 {
                let sev: HazardSeverity = buildingCollapse >= 4 ? .danger : .warning
                results.append(("building.2.crop.circle", "倒壊\(buildingCollapse)", sev))
            }
            if fire >= 3 {
                let sev: HazardSeverity = fire >= 4 ? .danger : .warning
                results.append(("flame.fill", "火災\(fire)", sev))
            }
            if combined >= 3 {
                let sev: HazardSeverity = combined >= 4 ? .danger : .warning
                results.append(("exclamationmark.triangle.fill", "総合\(combined)", sev))
            }
            return results
        }

        /// 全ハザード種別のラベル配列（詳細画面用 — 全ランク表示）
        var allLabels: [(icon: String, label: String, severity: HazardSeverity)] {
            var results: [(String, String, HazardSeverity)] = []
            if flood { results.append(("drop.fill", "洪水浸水", .warning)) }
            if inlandWater { results.append(("drop.fill", "内水浸水", .warning)) }
            if sediment { results.append(("mountain.2.fill", "土砂災害", .danger)) }
            if stormSurge { results.append(("wind", "高潮浸水", .warning)) }
            if tsunami { results.append(("water.waves", "津波浸水", .danger)) }
            if liquefaction { results.append(("waveform.path.ecg", "液状化", .warning)) }
            if buildingCollapse > 0 {
                let sev: HazardSeverity = buildingCollapse >= 4 ? .danger : (buildingCollapse >= 3 ? .warning : .info)
                results.append(("building.2.crop.circle", "建物倒壊 ランク\(buildingCollapse)", sev))
            }
            if fire > 0 {
                let sev: HazardSeverity = fire >= 4 ? .danger : (fire >= 3 ? .warning : .info)
                results.append(("flame.fill", "火災 ランク\(fire)", sev))
            }
            if combined > 0 {
                let sev: HazardSeverity = combined >= 4 ? .danger : (combined >= 3 ? .warning : .info)
                results.append(("exclamationmark.triangle.fill", "総合危険度 ランク\(combined)", sev))
            }
            return results
        }
    }

    enum HazardSeverity {
        case info     // 低リスク（緑〜グレー: ランク1-2）
        case warning  // 注意（黄〜オレンジ: ランク3）
        case danger   // 危険（赤: ランク4-5）
    }

    /// hazardInfo JSON をパースして HazardData を返す（キャッシュ付き）
    var parsedHazardData: HazardData {
        if let cached = _cache.hazard, cached.source == hazardInfo {
            return cached.result
        }
        let result = Self._parseHazardData(hazardInfo)
        _cache.hazard = (hazardInfo, result)
        return result
    }

    private static func _parseHazardData(_ info: String?) -> HazardData {
        guard let info, let data = info.data(using: .utf8),
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

    /// 重大なハザードリスクがあるか（一覧バッジ表示用）
    var hasHazardRisk: Bool {
        parsedHazardData.hasAnyHazard
    }

    /// ハザードデータが存在するか（詳細画面セクション表示用 — 低ランクでも表示）
    var hasHazardData: Bool {
        hazardInfo != nil && parsedHazardData.hasAnyData
    }

    // MARK: - コメント

    /// パース済みコメントリスト（日時昇順・キャッシュ付き）
    var parsedComments: [CommentData] {
        if let cached = _cache.comments, cached.source == commentsJSON {
            return cached.result
        }
        let result = Self._parseComments(commentsJSON)
        _cache.comments = (commentsJSON, result)
        return result
    }

    private static func _parseComments(_ json: String?) -> [CommentData] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? CommentData.decoder.decode([CommentData].self, from: data))?
            .sorted { $0.createdAt < $1.createdAt } ?? []
    }

    /// コメント数
    var commentCount: Int { parsedComments.count }

    /// コメントがあるか
    var hasComments: Bool { commentsJSON != nil && commentCount > 0 }

    /// 一覧表示用: 最新コメントのプレビュー
    var latestCommentPreview: String? {
        guard let latest = parsedComments.last else { return nil }
        return "\(latest.authorName): \(latest.text)"
    }

    // MARK: - 内見写真

    /// パース済み写真メタデータリスト（日時昇順・キャッシュ付き）
    var parsedPhotos: [PhotoMeta] {
        if let cached = _cache.photos, cached.source == photosJSON {
            return cached.result
        }
        let result = Self._parsePhotos(photosJSON)
        _cache.photos = (photosJSON, result)
        return result
    }

    private static func _parsePhotos(_ json: String?) -> [PhotoMeta] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? PhotoMeta.decoder.decode([PhotoMeta].self, from: data))?
            .sorted { $0.createdAt < $1.createdAt } ?? []
    }

    /// 写真枚数
    var photoCount: Int { parsedPhotos.count }

    /// 写真があるか
    var hasPhotos: Bool { photosJSON != nil && photoCount > 0 }

    // MARK: - 間取り図画像

    /// floorPlanImagesJSON をパースして URL 配列で返す（キャッシュ付き）
    var parsedFloorPlanImages: [URL] {
        if let cached = _cache.floorPlanImages, cached.source == floorPlanImagesJSON {
            return cached.result
        }
        let result = Self._parseFloorPlanImages(floorPlanImagesJSON)
        _cache.floorPlanImages = (floorPlanImagesJSON, result)
        return result
    }

    private static func _parseFloorPlanImages(_ json: String?) -> [URL] {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr.compactMap { URL(string: $0) }
    }

    /// 間取り図画像があるか
    var hasFloorPlanImages: Bool {
        floorPlanImagesJSON != nil && !parsedFloorPlanImages.isEmpty
    }

    // MARK: - SUUMO 物件写真

    /// SUUMO 物件写真1枚のデータ
    struct SuumoImage: Codable, Identifiable {
        var url: String
        var label: String

        var id: String { url }

        var resolvedURL: URL? { URL(string: url) }

        /// カテゴリ分類
        enum Category: String, CaseIterable {
            case exterior = "外観"
            case interior = "室内"
            case water = "水回り"
            case other = "その他"

            var iconName: String {
                switch self {
                case .exterior: return "building.2"
                case .interior: return "sofa"
                case .water: return "drop"
                case .other: return "photo"
                }
            }
        }

        /// label からカテゴリを判定
        var category: Category {
            if label.contains("外観") || label.contains("エントランス") { return .exterior }
            if label.contains("リビング") || label.contains("キッチン") || label.contains("居室")
                || label.contains("収納") || label.contains("眺望") || label.contains("バルコニー")
                || label.contains("玄関") {
                return .interior
            }
            if label.contains("浴室") || label.contains("洗面") || label.contains("トイレ") {
                return .water
            }
            return .other
        }
    }

    /// suumoImagesJSON をパースして SuumoImage 配列で返す（キャッシュ付き）
    var parsedSuumoImages: [SuumoImage] {
        if let cached = _cache.suumoImages, cached.source == suumoImagesJSON {
            return cached.result
        }
        let result = Self._parseSuumoImages(suumoImagesJSON)
        _cache.suumoImages = (suumoImagesJSON, result)
        return result
    }

    private static func _parseSuumoImages(_ json: String?) -> [SuumoImage] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SuumoImage].self, from: data)) ?? []
    }

    /// SUUMO 物件写真があるか
    var hasSuumoImages: Bool {
        suumoImagesJSON != nil && !parsedSuumoImages.isEmpty
    }

    /// カテゴリ別にグルーピングした SUUMO 物件写真
    var groupedSuumoImages: [(category: SuumoImage.Category, images: [SuumoImage])] {
        let images = parsedSuumoImages
        var groups: [(SuumoImage.Category, [SuumoImage])] = []
        for cat in SuumoImage.Category.allCases {
            let matched = images.filter { $0.category == cat }
            if !matched.isEmpty {
                groups.append((cat, matched))
            }
        }
        return groups
    }

    /// 一覧カードのサムネイル用 URL（外観写真を優先、なければ先頭画像にフォールバック）
    var thumbnailURL: URL? {
        let images = parsedSuumoImages
        // 外観カテゴリの画像を優先
        if let exterior = images.first(where: { $0.category == .exterior }) {
            return exterior.resolvedURL
        }
        // 外観写真がない場合は先頭画像にフォールバック
        return images.first?.resolvedURL
    }

    // MARK: - 通勤時間

    /// パース済み通勤時間データ（キャッシュ付き）
    var parsedCommuteInfo: CommuteData {
        if let cached = _cache.commuteInfo, cached.source == commuteInfoJSON {
            return cached.result
        }
        let result = Self._parseCommuteInfo(commuteInfoJSON)
        _cache.commuteInfo = (commuteInfoJSON, result)
        return result
    }

    private static func _parseCommuteInfo(_ json: String?) -> CommuteData {
        guard let json, let data = json.data(using: .utf8) else { return CommuteData() }
        return (try? CommuteData.decoder.decode(CommuteData.self, from: data)) ?? CommuteData()
    }

    /// 通勤時間データがあるか
    var hasCommuteInfo: Bool {
        let info = parsedCommuteInfo
        return info.playground != nil || info.m3career != nil
    }

    /// 一覧表示用: Playground 通勤時間
    var commutePlaygroundDisplay: String? {
        guard let pg = parsedCommuteInfo.playground else { return nil }
        return "\(pg.minutes)分"
    }

    /// 一覧表示用: M3Career 通勤時間
    var commuteM3CareerDisplay: String? {
        guard let m3 = parsedCommuteInfo.m3career else { return nil }
        return "\(m3.minutes)分"
    }

    // MARK: - 不動産情報ライブラリ相場データ

    /// 相場データの解析済み構造体
    struct MarketData {
        var ward: String
        var wardMedianM2Price: Int         // 円/m²
        var wardMeanM2Price: Int?          // 円/m²
        var priceRatio: Double?            // 掲載価格÷相場 (1.0=相場並み)
        var priceDiffMan: Int?             // 差額（万円, 正=割高）
        var sampleCount: Int
        var matchTier: Int                 // 1=精密, 2=標準, 3=広め, 4=区全体
        var matchDescription: String       // "港区・3LDK・50-80m²・築2005-2025年"
        var trend: String                  // "up" / "flat" / "down"
        var yoyChangePct: Double?          // 前年同期比変動率 (%)
        var quarterlyM2Prices: [QuarterlyPrice]
        var yearlyM2Prices: [YearlyPrice]  // 区レベル年次推移（駅データ集計）
        var sameBuildingTransactions: [SameBuildingTransaction]
        var station: StationMarketData?    // 駅レベル比較
        var dataSource: String

        struct QuarterlyPrice {
            var quarter: String            // "2024Q3"
            var medianM2Price: Int          // 円/m²
            var count: Int
        }

        struct YearlyPrice {
            var year: String               // "2024"
            var medianM2Price: Int          // 円/m²
            var count: Int
        }

        struct SameBuildingTransaction {
            var period: String             // "2025Q2"
            var floorPlan: String          // "3LDK"
            var area: Double               // 72.0
            var tradePriceMan: Int          // 9500 (万円)
            var m2Price: Int               // 1319444 (円/m²)

            /// m²単価の万円表示
            var m2PriceManDisplay: String {
                let man = Double(m2Price) / 10000.0
                return String(format: "%.1f万/m²", man)
            }

            /// 成約価格の表示
            var tradePriceDisplay: String {
                if tradePriceMan >= 10000 {
                    let oku = Double(tradePriceMan) / 10000.0
                    return String(format: "%.1f億円", oku)
                }
                return "\(tradePriceMan)万円"
            }

            /// 取引時期の表示（"2025Q2" → "2025年4-6月"）
            var periodDisplay: String {
                let parts = period.split(separator: "Q")
                guard parts.count == 2,
                      let year = parts.first,
                      let q = Int(parts.last ?? "") else { return period }
                let months: String
                switch q {
                case 1: months = "1-3月"
                case 2: months = "4-6月"
                case 3: months = "7-9月"
                case 4: months = "10-12月"
                default: months = ""
                }
                return "\(year)年\(months)"
            }
        }

        /// 駅レベル比較データ
        struct StationMarketData {
            var name: String                    // "品川"
            var medianM2Price: Int              // 円/m²
            var meanM2Price: Int?               // 円/m²
            var sampleCount: Int
            var priceRatio: Double?             // 掲載価格÷駅相場
            var priceDiffMan: Int?              // 差額（万円）
            var trend: String                   // "up" / "flat" / "down"
            var yoyChangePct: Double?           // 前年比変動率 (%)
            var quarterlyM2Prices: [QuarterlyPrice]
            var yearlyM2Prices: [YearlyPrice]
            var lines: [String]                 // 路線名リスト

            /// m²単価の万円表示
            var medianM2PriceManDisplay: String {
                let man = Double(medianM2Price) / 10000.0
                return String(format: "%.1f万/m²", man)
            }

            /// 乖離率テキスト
            var priceRatioDisplay: String {
                guard let ratio = priceRatio else { return "—" }
                let pct = (ratio - 1.0) * 100
                if abs(pct) < 2.0 { return "相場並み" }
                return pct > 0
                    ? String(format: "+%.0f%%（割高）", pct)
                    : String(format: "%.0f%%（割安）", pct)
            }

            /// 差額テキスト
            var priceDiffDisplay: String {
                guard let diff = priceDiffMan else { return "—" }
                if diff == 0 { return "±0万" }
                return diff > 0 ? "+\(diff)万" : "\(diff)万"
            }

            /// トレンドアイコン名
            var trendIconName: String {
                switch trend {
                case "up": return "arrow.up.right"
                case "down": return "arrow.down.right"
                default: return "arrow.right"
                }
            }

            /// トレンド表示テキスト
            var trendDisplay: String {
                switch trend {
                case "up": return "上昇傾向"
                case "down": return "下降傾向"
                default: return "横ばい"
                }
            }

            /// YoY 表示テキスト
            var yoyDisplay: String {
                guard let yoy = yoyChangePct else { return "—" }
                return String(format: "%+.1f%%", yoy)
            }
        }

        /// 相場との乖離率テキスト（例: "+8%（割高）", "−5%（割安）", "相場並み"）
        var priceRatioDisplay: String {
            guard let ratio = priceRatio else { return "—" }
            let pct = (ratio - 1.0) * 100
            if abs(pct) < 2.0 {
                return "相場並み"
            } else if pct > 0 {
                return String(format: "+%.0f%%（割高）", pct)
            } else {
                return String(format: "%.0f%%（割安）", pct)
            }
        }

        /// 差額テキスト（例: "+620万", "−350万"）
        var priceDiffDisplay: String {
            guard let diff = priceDiffMan else { return "—" }
            if diff == 0 { return "±0万" }
            return diff > 0 ? "+\(diff)万" : "\(diff)万"
        }

        /// トレンドアイコン名
        var trendIconName: String {
            switch trend {
            case "up": return "arrow.up.right"
            case "down": return "arrow.down.right"
            default: return "arrow.right"
            }
        }

        /// トレンド表示テキスト
        var trendDisplay: String {
            switch trend {
            case "up": return "上昇傾向"
            case "down": return "下降傾向"
            default: return "横ばい"
            }
        }

        /// m² 単価の万円表示
        var wardMedianM2PriceManDisplay: String {
            let man = Double(wardMedianM2Price) / 10000.0
            return String(format: "%.1f万/m²", man)
        }

        /// YoY 表示テキスト
        var yoyDisplay: String {
            guard let yoy = yoyChangePct else { return "—" }
            return String(format: "%+.1f%%", yoy)
        }

        /// マッチ条件の精度ラベル
        var matchTierLabel: String {
            switch matchTier {
            case 1: return "精密比較"
            case 2: return "標準比較"
            case 3: return "間取り比較"
            default: return "エリア比較"
            }
        }
    }

    /// reinfolibMarketData JSON を解析（キャッシュ付き）
    var parsedMarketData: MarketData? {
        if let cached = _cache.marketData, cached.source == reinfolibMarketData {
            return cached.result
        }
        let result = _parseMarketDataImpl()
        _cache.marketData = (reinfolibMarketData, result)
        return result
    }

    private func _parseMarketDataImpl() -> MarketData? {
        guard let json = reinfolibMarketData, !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let ward = dict["ward"] as? String ?? ""
        guard let medianM2 = dict["ward_median_m2_price"] as? Int else { return nil }

        let quarterlyRaw = dict["quarterly_m2_prices"] as? [[String: Any]] ?? []
        let quarterly = quarterlyRaw.compactMap { q -> MarketData.QuarterlyPrice? in
            guard let quarter = q["quarter"] as? String,
                  let price = q["median_m2_price"] as? Int else { return nil }
            return MarketData.QuarterlyPrice(
                quarter: quarter,
                medianM2Price: price,
                count: q["count"] as? Int ?? 0
            )
        }

        // 区レベル年次推移（駅データから集計）
        let yearlyRaw = dict["yearly_m2_prices"] as? [[String: Any]] ?? []
        let yearly = yearlyRaw.compactMap { y -> MarketData.YearlyPrice? in
            guard let year = y["year"] as? String,
                  let price = y["median_m2_price"] as? Int else { return nil }
            return MarketData.YearlyPrice(
                year: year, medianM2Price: price, count: y["count"] as? Int ?? 0
            )
        }

        // 同一マンション候補の成約事例
        let sbRaw = dict["same_building_transactions"] as? [[String: Any]] ?? []
        let sameBuildingTxs = sbRaw.compactMap { tx -> MarketData.SameBuildingTransaction? in
            guard let period = tx["period"] as? String else { return nil }
            return MarketData.SameBuildingTransaction(
                period: period,
                floorPlan: tx["floor_plan"] as? String ?? "",
                area: tx["area"] as? Double ?? 0,
                tradePriceMan: tx["trade_price_man"] as? Int ?? 0,
                m2Price: tx["m2_price"] as? Int ?? 0
            )
        }

        // 駅レベル比較
        var stationData: MarketData.StationMarketData?
        if let stDict = dict["station"] as? [String: Any],
           let stMedian = stDict["median_m2_price"] as? Int,
           let stName = stDict["name"] as? String, !stName.isEmpty {

            let stQuarterly = (stDict["quarterly_m2_prices"] as? [[String: Any]] ?? [])
                .compactMap { sq -> MarketData.QuarterlyPrice? in
                    guard let q = sq["quarter"] as? String,
                          let p = sq["median_m2_price"] as? Int else { return nil }
                    return MarketData.QuarterlyPrice(
                        quarter: q, medianM2Price: p, count: sq["count"] as? Int ?? 0
                    )
                }

            let stYearly = (stDict["yearly_m2_prices"] as? [[String: Any]] ?? [])
                .compactMap { sy -> MarketData.YearlyPrice? in
                    guard let y = sy["year"] as? String,
                          let p = sy["median_m2_price"] as? Int else { return nil }
                    return MarketData.YearlyPrice(
                        year: y, medianM2Price: p, count: sy["count"] as? Int ?? 0
                    )
                }

            stationData = MarketData.StationMarketData(
                name: stName,
                medianM2Price: stMedian,
                meanM2Price: stDict["mean_m2_price"] as? Int,
                sampleCount: stDict["sample_count"] as? Int ?? 0,
                priceRatio: stDict["price_ratio"] as? Double,
                priceDiffMan: stDict["price_diff_man"] as? Int,
                trend: stDict["trend"] as? String ?? "flat",
                yoyChangePct: stDict["yoy_change_pct"] as? Double,
                quarterlyM2Prices: stQuarterly,
                yearlyM2Prices: stYearly,
                lines: stDict["lines"] as? [String] ?? []
            )
        }

        return MarketData(
            ward: ward,
            wardMedianM2Price: medianM2,
            wardMeanM2Price: dict["ward_mean_m2_price"] as? Int,
            priceRatio: dict["price_ratio"] as? Double,
            priceDiffMan: dict["price_diff_man"] as? Int,
            sampleCount: dict["sample_count"] as? Int ?? 0,
            matchTier: dict["match_tier"] as? Int ?? 4,
            matchDescription: dict["match_description"] as? String ?? ward,
            trend: dict["trend"] as? String ?? "flat",
            yoyChangePct: dict["yoy_change_pct"] as? Double,
            quarterlyM2Prices: quarterly,
            yearlyM2Prices: yearly,
            sameBuildingTransactions: sameBuildingTxs,
            station: stationData,
            dataSource: dict["data_source"] as? String ?? "不動産情報ライブラリ（国土交通省）"
        )
    }

    /// 不動産情報ライブラリの相場データがあるか
    var hasMarketData: Bool { parsedMarketData != nil }

    // MARK: - 人口動態データ

    /// 人口動態データの解析済み構造体
    struct PopulationData {
        var ward: String
        var latestPopulation: Int
        var latestHouseholds: Int
        var popChange1yrPct: Double?        // 前年比変動率 (%)
        var popChange5yrPct: Double?        // 5年比変動率 (%)
        var populationHistory: [YearValue]  // 年次人口推移
        var householdHistory: [YearValue]   // 年次世帯数推移
        var dataSource: String

        // 高齢化率（65歳以上人口割合）— 国勢調査5年ごと
        var agingRateHistory: [AgingEntry]          // 当該区の推移
        var nationalAgingHistory: [AgingEntry]      // 全国平均
        var tokyo23AvgAgingHistory: [AgingEntry]    // 23区平均
        var latestAgingRate: Double?

        struct YearValue {
            var year: String
            var value: Int
        }

        struct AgingEntry {
            var year: String
            var rate: Double
        }

        /// 人口変動率テキスト（例: "+1.5%"）
        var popChange1yrDisplay: String {
            guard let pct = popChange1yrPct else { return "—" }
            return String(format: "%+.1f%%", pct)
        }

        /// 5年変動率テキスト（例: "+7.8%"）
        var popChange5yrDisplay: String {
            guard let pct = popChange5yrPct else { return "—" }
            return String(format: "%+.1f%%", pct)
        }

        /// 人口のフォーマット表示（例: "52.9万人"）
        var populationDisplay: String {
            let man = Double(latestPopulation) / 10000.0
            if man >= 10.0 {
                return String(format: "%.1f万人", man)
            }
            return "\(latestPopulation.formatted())人"
        }

        /// 世帯数のフォーマット表示（例: "28.8万世帯"）
        var householdsDisplay: String {
            let man = Double(latestHouseholds) / 10000.0
            if man >= 10.0 {
                return String(format: "%.1f万世帯", man)
            }
            return "\(latestHouseholds.formatted())世帯"
        }

        var latestAgingRateDisplay: String {
            guard let rate = latestAgingRate else { return "—" }
            return String(format: "%.1f%%", rate)
        }

        /// 人口変動が増加傾向か
        var isPopGrowing: Bool {
            (popChange1yrPct ?? 0) > 0
        }

        var hasAgingData: Bool {
            !agingRateHistory.isEmpty
        }
    }

    /// estatPopulationData JSON を解析（キャッシュ付き）
    var parsedPopulationData: PopulationData? {
        if let cached = _cache.populationData, cached.source == estatPopulationData {
            return cached.result
        }
        let result = _parsePopulationDataImpl()
        _cache.populationData = (estatPopulationData, result)
        return result
    }

    private func _parsePopulationDataImpl() -> PopulationData? {
        guard let json = estatPopulationData, !json.isEmpty,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let ward = dict["ward"] as? String ?? ""
        guard let population = dict["latest_population"] as? Int,
              let households = dict["latest_households"] as? Int else { return nil }

        let popHistoryRaw = dict["population_history"] as? [[String: Any]] ?? []
        let popHistory = popHistoryRaw.compactMap { h -> PopulationData.YearValue? in
            guard let year = h["year"] as? String,
                  let pop = h["population"] as? Int else { return nil }
            return PopulationData.YearValue(year: year, value: pop)
        }

        let hhHistoryRaw = dict["household_history"] as? [[String: Any]] ?? []
        let hhHistory = hhHistoryRaw.compactMap { h -> PopulationData.YearValue? in
            guard let year = h["year"] as? String,
                  let hh = h["households"] as? Int else { return nil }
            return PopulationData.YearValue(year: year, value: hh)
        }

        func parseAgingEntries(_ key: String) -> [PopulationData.AgingEntry] {
            let raw = dict[key] as? [[String: Any]] ?? []
            return raw.compactMap { h in
                guard let year = h["year"] as? String,
                      let rate = h["aging_rate"] as? Double else { return nil }
                return PopulationData.AgingEntry(year: year, rate: rate)
            }
        }

        return PopulationData(
            ward: ward,
            latestPopulation: population,
            latestHouseholds: households,
            popChange1yrPct: dict["pop_change_1yr_pct"] as? Double,
            popChange5yrPct: dict["pop_change_5yr_pct"] as? Double,
            populationHistory: popHistory,
            householdHistory: hhHistory,
            dataSource: dict["data_source"] as? String ?? "e-Stat（総務省統計局）",
            agingRateHistory: parseAgingEntries("aging_rate_history"),
            nationalAgingHistory: parseAgingEntries("national_aging_history"),
            tokyo23AvgAgingHistory: parseAgingEntries("tokyo23_avg_aging_history"),
            latestAgingRate: dict["latest_aging_rate"] as? Double
        )
    }

    /// 人口動態データがあるか
    var hasPopulationData: Bool { parsedPopulationData != nil }
}

// MARK: - 通勤時間データ

/// 2つのオフィスへの通勤時間情報
struct CommuteData: Codable {
    var playground: CommuteDestination?
    var m3career: CommuteDestination?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// JSON 文字列にエンコード
    func encode() -> String? {
        guard let data = try? Self.encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// いずれかの目的地がフォールバック概算になっているか
    var hasFallbackEstimate: Bool {
        (playground?.isFallbackEstimate ?? false) || (m3career?.isFallbackEstimate ?? false)
    }
}

/// 1つの目的地への通勤時間情報
struct CommuteDestination: Codable {
    /// 所要時間（分）
    var minutes: Int
    /// 経路概要（例: "東京メトロ半蔵門線→半蔵門駅 徒歩5分"）
    var summary: String
    /// 乗り換え回数
    var transfers: Int?
    /// 計算日時
    var calculatedAt: Date

    /// Apple Maps から正規の経路が取得できず、直線距離ベースの概算になっているか
    var isFallbackEstimate: Bool {
        summary.contains("経路情報取得不可")
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
    var ss_address: String?
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
    var management_fee: Int?
    var repair_reserve_fund: Int?
    var direction: String?
    var balcony_area_m2: Double?
    var parking: String?
    var constructor: String?
    var zoning: String?
    var repair_fund_onetime: Int?
    var feature_tags: [String]?
    var list_ward_roman: String?

    // 重複集約
    var duplicate_count: Int?

    // ジオコーディング済み座標（パイプライン側で付与）
    var latitude: Double?
    var longitude: Double?

    // ハザード情報
    var hazard_info: String?

    // 住まいサーフィン評価データ
    var ss_lookup_status: String?
    var ss_profit_pct: Int?
    var ss_oki_price_70m2: Int?
    var ss_m2_discount: Int?
    var ss_value_judgment: String?
    var ss_station_rank: String?
    var ss_ward_rank: String?
    var ss_sumai_surfin_url: String?
    var ss_appreciation_rate: Double?
    var ss_favorite_count: Int?
    var ss_purchase_judgment: String?
    var ss_radar_data: String?
    var ss_sim_best_5yr: Int?
    var ss_sim_best_10yr: Int?
    var ss_sim_standard_5yr: Int?
    var ss_sim_standard_10yr: Int?
    var ss_sim_worst_5yr: Int?
    var ss_sim_worst_10yr: Int?
    var ss_loan_balance_5yr: Int?
    var ss_loan_balance_10yr: Int?
    var ss_sim_base_price: Int?
    var ss_new_m2_price: Int?
    var ss_forecast_m2_price: Int?
    var ss_forecast_change_rate: Double?
    var ss_past_market_trends: String?
    var ss_surrounding_properties: String?
    var ss_price_judgments: String?

    // 間取り図画像 URL 配列（スクレイピングツールから取得）
    var floor_plan_images: [String]?

    // SUUMO 物件写真（スクレイピングツールから取得）
    var suumo_images: [Listing.SuumoImage]?

    // 通勤時間（駅ベース概算、パイプライン側で付与）
    var commute_info: String?

    // 不動産情報ライブラリ相場データ（パイプライン側で付与）
    var reinfolib_market_data: String?

    // e-Stat 人口動態データ（パイプライン側で付与）
    var estat_population_data: String?

    // サーバーサイドで判定された新着フラグ（前回スクレイピングとの差分比較）
    var is_new: Bool?
}

extension Listing {
    // MARK: - ブランド名 英字→カタカナ変換辞書
    // デベロッパーのマンションブランド名。住まいサーフィン・一般的にはカタカナ表記が標準。
    private static let brandToKana: [(pattern: String, kana: String)] = [
        ("brillia", "ブリリア"),       // 東京建物
        ("livcity", "リブシティ"),     // スターツ
        ("belista", "ベリスタ"),       // 大和地所レジデンス
        ("livio", "リビオ"),          // 日鉄興和不動産
        ("cravia", "クレヴィア"),      // 伊藤忠都市開発
        ("cielia", "シエリア"),        // 関電不動産開発
        ("premia", "プレミア"),
        ("arkmark", "アークマーク"),    // フジクリエイション
        ("ohana", "オハナ"),          // 野村不動産
        ("atlas", "アトラス"),         // 旭化成不動産レジデンス
        ("branz", "ブランズ"),         // 東急不動産
    ]

    /// スクレイピングで混入しがちなノイズを物件名から除去し、純粋なマンション名を返す。
    ///
    /// 処理順序:
    /// 1. NFKC正規化（全角英数→半角統一）
    /// 2. 広告装飾の除去（【...】, ◆, ■□■, ～以降, ペット飼育可能♪ 等）
    /// 3. 括弧内の別名表記を除去（（Brillia 大島 Pa…）等）
    /// 4. 英字ブランド名→カタカナ変換（Brillia→ブリリア 等）
    /// 5. 棟名の除去（A棟, ノース棟, 2号棟 等）
    /// 6. 階数の除去（9F, 1階, 地下1階 等）
    /// 7. 末尾の英語サブネームを除去（GRAN WARD TERRACE 等）
    /// 8. 既存の接頭辞/接尾辞クリーニング（新築マンション, 閲覧済, 販売期 等）
    static func cleanListingName(_ name: String) -> String {
        // NFKC正規化（全角英数→半角統一）
        var s = name.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespaces)

        // 「掲載物件X件」「見学予約」のようなものは物件名ではない
        if s.range(of: #"^掲載物件\d+件$"#, options: .regularExpression) != nil { return "" }
        if s == "見学予約" || s == "noimage" { return "" }

        // ── 広告装飾の除去 ──
        // 【...】を除去（【弊社限定取扱物件】、【売主物件】、【VECS】等）
        s = s.replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression)
        // ◆以降をすべて除去（◆2LDk◆角部屋◆リフォーム済◆… 等の装飾全体）
        // ペア除去（◆X◆）ではなく最初の◆から末尾まで一括除去することで
        // 残留テキスト（角部屋、ペット可等）を防ぐ
        s = s.replacingOccurrences(of: #"◆.*$"#, with: "", options: .regularExpression)
        // ■□ 等の記号装飾を除去
        s = s.replacingOccurrences(of: #"[■□]+\s*"#, with: "", options: .regularExpression)
        // ～以降の駅距離・説明文を除去
        s = s.replacingOccurrences(of: #"[~～].*$"#, with: "", options: .regularExpression)
        // 末尾の広告文句
        s = s.replacingOccurrences(of: #"ペット飼育可能.*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[♪！!☆★]+$"#, with: "", options: .regularExpression)

        // ── 括弧内の別名表記を除去 ──
        // 閉じ括弧がある場合: （Brillia 大島 Park Side）
        s = s.replacingOccurrences(of: #"[（(][^）)]*[）)]"#, with: "", options: .regularExpression)
        // 閉じ括弧がない場合（SUUMO の文字数制限で切れている）: （Brillia 大島 Pa…
        s = s.replacingOccurrences(of: #"[（(][^）)]*$"#, with: "", options: .regularExpression)

        s = s.trimmingCharacters(in: .whitespaces)

        // ── 英字ブランド名→カタカナ変換 ──
        for brand in brandToKana {
            s = s.replacingOccurrences(
                of: brand.pattern,
                with: brand.kana,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // ── 棟名の除去 ──
        s = s.replacingOccurrences(of: #"\s*[A-Za-z]棟$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\d+号棟$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*(ノース|サウス|イースト|ウエスト|ウェスト|テラス|セントラル)棟$"#, with: "", options: .regularExpression)

        // ── 階数の除去 ──
        s = s.replacingOccurrences(of: #"\s*\d+[Ff]$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*(?:地下)?\d+階.*$"#, with: "", options: .regularExpression)

        // ── 末尾の英語サブネーム除去 ──
        // 日本語文字の後に続く英字列を除去（GRAN WARD TERRACE, activewing 等）
        // 英字3文字未満またはローマ数字のみ（I, II, III 等）の場合は残す
        s = Self.stripTrailingEnglish(s)

        s = s.trimmingCharacters(in: .whitespaces)

        // ── 既存のクリーニング ──
        // 先頭の「新築マンション」「マンション未入居」「マンション」を除去
        if s.hasPrefix("新築マンション") { s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if s.hasPrefix("マンション未入居") { s = String(s.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        if s.hasPrefix("マンション") { s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        // 末尾の「閲覧済」を除去
        if s.hasSuffix("閲覧済") { s = String(s.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        // 販売期情報を除去: 「( 第2期 2次 )」「第1期1次」
        if let range = s.range(of: #"\s*[（(]\s*第\d+期\s*\d*次?\s*[）)]\s*$"#, options: .regularExpression) { s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if let range = s.range(of: #"\s*第\d+期\s*\d*次?\s*$"#, options: .regularExpression) { s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }

        // ── 不動産説明文の除去 ──
        // 「PROJECT 東南角部屋・新規リノベーション」等、建物名に続く説明的テキスト
        s = s.replacingOccurrences(of: #"\s+PROJECT\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        // 建物名の後に残る不動産用語を除去（角部屋、リフォーム済 等）
        // 先頭に空白がある場合のみ除去（建物名の一部を壊さないため）
        s = s.replacingOccurrences(
            of: #"\s+(角部屋|リフォーム済み?|フルリフォーム|リノベーション|フルリノベーション|大規模修繕.*|ペット(?:可|飼育可|相談)|新規.*リノベ.*|南東向|南西向|北東向|北西向|南向き?|北向き?|東向き?|西向き?|即入居可?|オーナーチェンジ).*$"#,
            with: "",
            options: .regularExpression
        )

        // 連続スペースを正規化
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 末尾の英語サブネームを除去する（GRAN WARD TERRACE, activewing 等）。
    /// ローマ数字（I, II, III, IV 等）は建物名の一部なので除去しない。
    private static func stripTrailingEnglish(_ s: String) -> String {
        // 日本語文字（ひらがな・カタカナ・漢字・長音記号）の最後の位置を探す
        guard let lastCJK = s.range(
            of: #"[\p{Hiragana}\p{Katakana}\p{Han}ー](?=[^\p{Hiragana}\p{Katakana}\p{Han}ー]*$)"#,
            options: .regularExpression
        ) else { return s }

        let after = String(s[lastCJK.upperBound...])
        // 英字のみ抽出
        let alphaOnly = after.filter { $0.isASCII && $0.isLetter }
        // 英字3文字未満 → 除去しない（I, II 等のローマ数字）
        guard alphaOnly.count >= 3 else { return s }
        // 全文字がローマ数字文字（I,V,X,L,C,D,M）→ 除去しない
        let romanChars: Set<Character> = ["I", "V", "X", "L", "C", "D", "M",
                                          "i", "v", "x", "l", "c", "d", "m"]
        if alphaOnly.allSatisfy({ romanChars.contains($0) }) { return s }
        // 末尾の英語部分を除去
        return String(s[...s.index(before: lastCJK.upperBound)])
    }

    static func from(dto: ListingDTO, fetchedAt: Date = .now) -> Listing? {
        guard let url = dto.url, !url.isEmpty,
              let rawName = dto.name, !rawName.isEmpty else { return nil }
        let name = cleanListingName(rawName)
        guard !name.isEmpty else { return nil }
        // floor_plan_images 配列を JSON 文字列に変換
        var floorPlanJSON: String?
        if let images = dto.floor_plan_images, !images.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: images) {
            floorPlanJSON = String(data: data, encoding: .utf8)
        }
        // suumo_images 配列を JSON 文字列に変換
        var suumoImagesJSON: String?
        if let imgs = dto.suumo_images, !imgs.isEmpty,
           let data = try? JSONEncoder().encode(imgs) {
            suumoImagesJSON = String(data: data, encoding: .utf8)
        }
        // feature_tags 配列を JSON 文字列に変換
        var featureTagsJSON: String?
        if let tags = dto.feature_tags, !tags.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: tags) {
            featureTagsJSON = String(data: data, encoding: .utf8)
        }
        return Listing(
            source: dto.source,
            url: url,
            name: name,
            priceMan: dto.price_man,
            address: dto.address,
            ssAddress: dto.ss_address,
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
            managementFee: dto.management_fee,
            repairReserveFund: dto.repair_reserve_fund,
            direction: dto.direction,
            balconyAreaM2: dto.balcony_area_m2,
            parking: dto.parking,
            constructor: dto.constructor,
            zoning: dto.zoning,
            repairFundOnetime: dto.repair_fund_onetime,
            featureTagsJSON: featureTagsJSON,
            listWardRoman: dto.list_ward_roman,
            floorPlanImagesJSON: floorPlanJSON,
            suumoImagesJSON: suumoImagesJSON,
            fetchedAt: fetchedAt,
            isNew: dto.is_new ?? false,
            propertyType: dto.property_type ?? "chuko",
            duplicateCount: dto.duplicate_count ?? 1,
            priceMaxMan: dto.price_max_man,
            areaMaxM2: dto.area_max_m2,
            deliveryDate: dto.delivery_date,
            latitude: dto.latitude,
            longitude: dto.longitude,
            hazardInfo: dto.hazard_info,
            commuteInfoJSON: dto.commute_info,
            ssLookupStatus: dto.ss_lookup_status,
            ssProfitPct: dto.ss_profit_pct,
            ssOkiPrice70m2: dto.ss_oki_price_70m2,
            ssM2Discount: dto.ss_m2_discount,
            ssValueJudgment: dto.ss_value_judgment,
            ssStationRank: dto.ss_station_rank,
            ssWardRank: dto.ss_ward_rank,
            ssSumaiSurfinURL: dto.ss_sumai_surfin_url,
            ssAppreciationRate: dto.ss_appreciation_rate,
            ssFavoriteCount: dto.ss_favorite_count,
            ssPurchaseJudgment: dto.ss_purchase_judgment,
            ssRadarData: dto.ss_radar_data,
            ssSimBest5yr: dto.ss_sim_best_5yr,
            ssSimBest10yr: dto.ss_sim_best_10yr,
            ssSimStandard5yr: dto.ss_sim_standard_5yr,
            ssSimStandard10yr: dto.ss_sim_standard_10yr,
            ssSimWorst5yr: dto.ss_sim_worst_5yr,
            ssSimWorst10yr: dto.ss_sim_worst_10yr,
            ssLoanBalance5yr: dto.ss_loan_balance_5yr,
            ssLoanBalance10yr: dto.ss_loan_balance_10yr,
            ssSimBasePrice: dto.ss_sim_base_price,
            ssNewM2Price: dto.ss_new_m2_price,
            ssForecastM2Price: dto.ss_forecast_m2_price,
            ssForecastChangeRate: dto.ss_forecast_change_rate,
            ssPastMarketTrends: dto.ss_past_market_trends,
            ssSurroundingProperties: dto.ss_surrounding_properties,
            ssPriceJudgments: dto.ss_price_judgments,
            reinfolibMarketData: dto.reinfolib_market_data,
            estatPopulationData: dto.estat_population_data
        )
    }
}

// MARK: - コメントデータ

/// 物件に対する1件のコメント。Firestore で家族間共有される。
struct CommentData: Codable, Identifiable {
    var id: String
    var text: String
    var authorName: String
    var authorId: String
    var createdAt: Date
    /// 編集された日時（nil なら未編集）
    var editedAt: Date?

    /// 編集済みかどうか
    var isEdited: Bool { editedAt != nil }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// コメント配列を JSON 文字列にエンコード
    static func encode(_ comments: [CommentData]) -> String? {
        guard let data = try? encoder.encode(comments) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 内見写真メタデータ

/// 物件に紐づく1枚の内見写真のメタデータ。画像ファイル自体はアプリの Documents ディレクトリに保存。
/// クラウド共有時は Firebase Storage にもアップロードされ、storagePath にパスが記録される。
struct PhotoMeta: Codable, Identifiable {
    var id: String
    var fileName: String
    var createdAt: Date

    // クラウド共有用フィールド（全て Optional: 既存データと互換性を保つ）
    /// アップロードしたユーザーの表示名
    var authorName: String?
    /// アップロードしたユーザーの Firebase UID
    var authorId: String?
    /// Firebase Storage 上のパス（nil = 未アップロード or ローカルのみ）
    var storagePath: String?

    /// 自分がアップロードした写真かどうか（authorId が nil の場合は既存写真として自分の写真扱い）
    func isOwnedBy(userId: String?) -> Bool {
        guard let authorId else { return true } // マイグレーション前の既存写真
        return authorId == userId
    }

    /// クラウドにアップロード済みかどうか
    var isUploaded: Bool { storagePath != nil }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// 写真メタデータ配列を JSON 文字列にエンコード
    static func encode(_ photos: [PhotoMeta]) -> String? {
        guard let data = try? encoder.encode(photos) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - @Model は PersistentModel 経由で Identifiable に自動準拠
