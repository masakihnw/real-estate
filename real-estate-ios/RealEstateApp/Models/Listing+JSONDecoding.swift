//
//  Listing+JSONDecoding.swift
//  RealEstateApp
//
//  ListingDTO の定義と Listing への変換ロジック。
//  latest.json / latest_shinchiku.json 形式に対応。
//

import Foundation
import SwiftData

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
    var commute_info_v2: String?

    // 不動産情報ライブラリ相場データ（パイプライン側で付与）
    var reinfolib_market_data: String?

    // マンションレビューデータ（パイプライン側で付与）
    var mansion_review_data: String?

    // e-Stat 人口動態データ（パイプライン側で付与）
    var estat_population_data: String?

    // 投資判断支援データ
    var price_history: [Listing.PriceHistoryEntry]?
    var first_seen_at: String?
    var price_fairness_score: Int?
    var resale_liquidity_score: Int?
    var competing_listings_count: Int?
    var listing_score: Int?

    // サーバーサイドで判定された新着フラグ（前回スクレイピングとの差分比較）
    var is_new: Bool?
    // 新着かつ同一マンション名が前回データに無い＝新規マンション（false＝既存マンションの別部屋）
    var is_new_building: Bool?
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
        // ◆NAME◆ → NAME（先頭◆で囲まれた物件名を抽出）
        if s.hasPrefix("◆"), s.hasSuffix("◆") {
            let inner = String(s.dropFirst().dropLast())
            if !inner.contains("◆") {
                s = inner.trimmingCharacters(in: .whitespaces)
            } else {
                s = s.replacingOccurrences(of: #"◆.*$"#, with: "", options: .regularExpression)
            }
        } else {
            // ◆以降をすべて除去（◆2LDk◆角部屋◆リフォーム済◆… 等の装飾全体）
            s = s.replacingOccurrences(of: #"◆.*$"#, with: "", options: .regularExpression)
        }
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
            isNewBuilding: dto.is_new_building ?? false,
            propertyType: dto.property_type ?? "chuko",
            duplicateCount: dto.duplicate_count ?? 1,
            priceMaxMan: dto.price_max_man,
            areaMaxM2: dto.area_max_m2,
            deliveryDate: dto.delivery_date,
            latitude: dto.latitude,
            longitude: dto.longitude,
            hazardInfo: dto.hazard_info,
            commuteInfoJSON: dto.commute_info,
            commuteInfoV2JSON: dto.commute_info_v2,
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
            mansionReviewData: dto.mansion_review_data,
            estatPopulationData: dto.estat_population_data,
            priceHistoryJSON: {
                if let history = dto.price_history, !history.isEmpty,
                   let data = try? JSONEncoder().encode(history) {
                    return String(data: data, encoding: .utf8)
                }
                return nil
            }(),
            firstSeenAt: dto.first_seen_at,
            priceFairnessScore: dto.price_fairness_score,
            resaleLiquidityScore: dto.resale_liquidity_score,
            competingListingsCount: dto.competing_listings_count,
            listingScore: dto.listing_score
        )
    }
}
