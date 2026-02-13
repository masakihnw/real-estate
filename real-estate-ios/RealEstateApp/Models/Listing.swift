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

    /// 内見写真メタデータ JSON 文字列（ローカル保存）
    /// フォーマット: [{"id":"...","fileName":"...","createdAt":"ISO8601"}]
    var photosJSON: String?

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
        listWardRoman: String? = nil,
        fetchedAt: Date = .now,
        addedAt: Date = .now,
        memo: String? = nil,
        isLiked: Bool = false,
        isDelisted: Bool = false,
        propertyType: String = "chuko",
        duplicateCount: Int = 1,
        priceMaxMan: Int? = nil,
        areaMaxM2: Double? = nil,
        deliveryDate: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        hazardInfo: String? = nil,
        commuteInfoJSON: String? = nil,
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
        self.listWardRoman = listWardRoman
        self.fetchedAt = fetchedAt
        self.addedAt = addedAt
        self.memo = memo
        self.isLiked = isLiked
        self.isDelisted = isDelisted
        self.propertyType = propertyType
        self.duplicateCount = duplicateCount
        self.priceMaxMan = priceMaxMan
        self.areaMaxM2 = areaMaxM2
        self.deliveryDate = deliveryDate
        self.latitude = latitude
        self.longitude = longitude
        self.hazardInfo = hazardInfo
        self.commuteInfoJSON = commuteInfoJSON
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

    /// 複数戸が同一条件で売り出されているか
    var hasMultipleUnits: Bool { duplicateCount > 1 }

    /// 表示用: 複数戸売出バッジテキスト（例: "2戸売出中"）
    var duplicateCountDisplay: String? {
        guard duplicateCount > 1 else { return nil }
        return "\(duplicateCount)戸売出中"
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

    /// 追加から24時間以内かどうか（Newバッジ表示用）
    var isNew: Bool {
        addedAt.timeIntervalSinceNow > -24 * 3600
    }

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

    // MARK: - 周辺物件データ

    /// 周辺の中古マンション相場の1件
    struct SurroundingProperty: Identifiable {
        let id = UUID()
        let name: String
        let appreciationRate: Double?  // 中古値上がり率 (%)
        let okiPrice70m2: Int?         // 沖式中古時価 70m²換算 (万円)
        let url: String?               // 住まいサーフィンURL
    }

    /// ssSurroundingProperties JSON をパースして配列で返す
    var parsedSurroundingProperties: [SurroundingProperty] {
        guard let json = ssSurroundingProperties,
              let data = json.data(using: .utf8),
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

    /// ssPriceJudgments JSON をパースして配列で返す
    var parsedPriceJudgments: [PriceJudgmentUnit] {
        guard let json = ssPriceJudgments,
              let data = json.data(using: .utf8),
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

    /// ssRadarData JSON をパースしてレーダーチャートデータを返す。
    /// 対応形式:
    ///   1. named-key 形式: {"oki_price_m2":65.3, "build_age":58.2, ...}
    ///   2. labels/values 形式 (旧): {"labels":["沖式中古時価m²単価",...], "values":[65.3,...]}
    /// JSON がない場合は既存フィールドからフォールバック計算する。
    var parsedRadarData: RadarData? {
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

    /// ssPastMarketTrends JSON をパースして配列を返す
    var parsedMarketTrends: [MarketTrendEntry] {
        guard let json = ssPastMarketTrends,
              let data = json.data(using: .utf8),
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
    /// 優先順位:
    ///   1. `ssValueJudgment` — ブラウザ自動化 or enricher で設定済みの値
    ///   2. `ssPriceJudgments` — 住戸ごとの判定から掲載価格に最も近い住戸を採用
    ///   3. 沖式中古時価との比較で推定（フォールバック）
    var computedPriceJudgment: String? {
        // 1. enricher / ブラウザ自動化で設定済みならそれを使用
        if let j = ssValueJudgment, !j.isEmpty {
            return j
        }
        // 2. 住戸ごとの割安判定から掲載価格に最も近い住戸を採用
        if let j = bestMatchingPriceJudgment {
            return j
        }
        // 3. 中古のみ: 沖式中古時価との比較で計算（フォールバック）
        //    住まいサーフィンの閾値: 割安(10%〜), やや割安(3.1〜9.9%), 適正(-8〜3%), やや割高(-8.1〜-14.9%), 割高(-15%〜)
        guard !isShinchiku,
              let okiForArea = ssOkiPriceForArea, okiForArea > 0,
              let price = priceMan, price > 0 else {
            return nil
        }
        let diffRate = (Double(price) - Double(okiForArea)) / Double(okiForArea)
        if diffRate <= -0.15 {
            return "割安"
        } else if diffRate <= -0.081 {
            return "やや割安"
        } else if diffRate <= 0.03 {
            return "適正価格"
        } else if diffRate <= 0.10 {
            return "やや割高"
        } else {
            return "割高"
        }
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

    /// 重大なハザードリスクがあるか（一覧バッジ表示用）
    var hasHazardRisk: Bool {
        parsedHazardData.hasAnyHazard
    }

    /// ハザードデータが存在するか（詳細画面セクション表示用 — 低ランクでも表示）
    var hasHazardData: Bool {
        hazardInfo != nil && parsedHazardData.hasAnyData
    }

    // MARK: - コメント

    /// パース済みコメントリスト（日時昇順）
    var parsedComments: [CommentData] {
        guard let json = commentsJSON,
              let data = json.data(using: .utf8) else { return [] }
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

    /// パース済み写真メタデータリスト（日時昇順）
    var parsedPhotos: [PhotoMeta] {
        guard let json = photosJSON,
              let data = json.data(using: .utf8) else { return [] }
        return (try? PhotoMeta.decoder.decode([PhotoMeta].self, from: data))?
            .sorted { $0.createdAt < $1.createdAt } ?? []
    }

    /// 写真枚数
    var photoCount: Int { parsedPhotos.count }

    /// 写真があるか
    var hasPhotos: Bool { photosJSON != nil && photoCount > 0 }

    // MARK: - 通勤時間

    /// パース済み通勤時間データ
    var parsedCommuteInfo: CommuteData {
        guard let json = commuteInfoJSON,
              let data = json.data(using: .utf8) else { return CommuteData() }
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

    /// reinfolibMarketData JSON を解析
    var parsedMarketData: MarketData? {
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

        struct YearValue {
            var year: String
            var value: Int
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

        /// 人口変動が増加傾向か
        var isPopGrowing: Bool {
            (popChange1yrPct ?? 0) > 0
        }
    }

    /// estatPopulationData JSON を解析
    var parsedPopulationData: PopulationData? {
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

        return PopulationData(
            ward: ward,
            latestPopulation: population,
            latestHouseholds: households,
            popChange1yrPct: dict["pop_change_1yr_pct"] as? Double,
            popChange5yrPct: dict["pop_change_5yr_pct"] as? Double,
            populationHistory: popHistory,
            householdHistory: hhHistory,
            dataSource: dict["data_source"] as? String ?? "e-Stat（総務省統計局）"
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
    var list_ward_roman: String?

    // 重複集約
    var duplicate_count: Int?

    // ジオコーディング済み座標（パイプライン側で付与）
    var latitude: Double?
    var longitude: Double?

    // ハザード情報
    var hazard_info: String?

    // 住まいサーフィン評価データ
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

    // 通勤時間（駅ベース概算、パイプライン側で付与）
    var commute_info: String?

    // 不動産情報ライブラリ相場データ（パイプライン側で付与）
    var reinfolib_market_data: String?

    // e-Stat 人口動態データ（パイプライン側で付与）
    var estat_population_data: String?
}

extension Listing {
    /// スクレイピングで混入しがちなノイズを物件名から除去
    static func cleanListingName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        // 「掲載物件X件」のようなものは物件名ではない
        if s.range(of: #"^掲載物件\d+件$"#, options: .regularExpression) != nil { return "" }
        // 先頭の「新築マンション」「マンション未入居」「マンション」を除去（長い方から先に試す）
        if s.hasPrefix("新築マンション") { s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if s.hasPrefix("マンション未入居") { s = String(s.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        if s.hasPrefix("マンション") { s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        // 末尾の「閲覧済」を除去
        if s.hasSuffix("閲覧済") { s = String(s.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        // 販売期情報を除去: 「( 第2期 2次 )」「第1期1次」
        if let range = s.range(of: #"\s*[（(]\s*第\d+期\s*\d*次?\s*[）)]\s*$"#, options: .regularExpression) { s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if let range = s.range(of: #"\s*第\d+期\s*\d*次?\s*$"#, options: .regularExpression) { s = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return s
    }

    static func from(dto: ListingDTO, fetchedAt: Date = .now) -> Listing? {
        guard let url = dto.url, !url.isEmpty,
              let rawName = dto.name, !rawName.isEmpty else { return nil }
        let name = cleanListingName(rawName)
        guard !name.isEmpty else { return nil }
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
            listWardRoman: dto.list_ward_roman,
            fetchedAt: fetchedAt,
            propertyType: dto.property_type ?? "chuko",
            duplicateCount: dto.duplicate_count ?? 1,
            priceMaxMan: dto.price_max_man,
            areaMaxM2: dto.area_max_m2,
            deliveryDate: dto.delivery_date,
            latitude: dto.latitude,
            longitude: dto.longitude,
            hazardInfo: dto.hazard_info,
            // commuteInfoJSON: JSON 概算は使わず Apple Maps (MKDirections) で正確に計算する
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
