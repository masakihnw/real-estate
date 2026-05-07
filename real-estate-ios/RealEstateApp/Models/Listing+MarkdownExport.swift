//
//  Listing+MarkdownExport.swift
//  RealEstateApp
//
//  Listing の Markdown エクスポートと AI 相談プロンプト生成。
//  toMarkdown(), toAIConsultationPrompt(otherCandidates:buyerProfile:),
//  toAIComparisonPrompt(listings:buyerProfile:) を含む。
//

import Foundation

// MARK: - Markdown エクスポート / AI 相談

extension Listing {

    /// 物件情報を構造化された Markdown 文字列に変換する。
    /// 「事実情報」と「参考情報」を明確に分離し、分析データにはデータソースと算出根拠を併記する。
    func toMarkdown() -> String {
        var md = "# \(name)\n\n"

        // ── 事実情報 ──

        md += "## 基本情報\n\n"
        md += "| 項目 | 内容 |\n|---|---|\n"
        md += "| 種別 | \(isShinchiku ? "新築マンション" : "中古マンション") |\n"
        md += "| 価格 | \(priceDisplay) |\n"
        if let area = areaM2 {
            if let hi = areaMaxM2, hi != area {
                md += "| 専有面積 | \(String(format: "%.1f〜%.1f㎡", area, hi)) |\n"
            } else {
                md += "| 専有面積 | \(String(format: "%.1f㎡", area)) |\n"
            }
        }
        md += "| 坪単価 | \(tsuboUnitPriceDisplay) |\n"
        if let layout { md += "| 間取り | \(layout) |\n" }
        if let addr = ssAddress ?? address { md += "| 住所 | \(addr) |\n" }

        let stations = parsedStations
        if !stations.isEmpty {
            for (i, st) in stations.enumerated() {
                let label = i == 0 ? "最寄駅" : "他最寄駅\(i)"
                var val = st.fullText
                if let w = st.walkMin { val += "（徒歩\(w)分）" }
                md += "| \(label) | \(val) |\n"
            }
        }

        if isShinchiku {
            if let total = floorTotal { md += "| 階建 | \(total)階建 |\n" }
            if let delivery = deliveryDate { md += "| 入居時期 | \(delivery) |\n" }
        } else {
            md += "| 築年 | \(builtDisplay) |\n"
            let floor = floorDisplay
            if !floor.isEmpty { md += "| 所在階/階建 | \(floor) |\n" }
        }
        if let units = totalUnits { md += "| 総戸数 | \(units)戸 |\n" }
        if let dir = direction, !dir.isEmpty { md += "| 向き | \(dir) |\n" }
        if let b = balconyAreaM2 { md += "| バルコニー | \(String(format: "%.2f㎡", b)) |\n" }
        if let own = ownership, !own.isEmpty { md += "| 権利形態 | \(own) |\n" }
        if let z = zoning, !z.isEmpty { md += "| 用途地域 | \(z) |\n" }
        if let p = parking, !p.isEmpty { md += "| 駐車場 | \(p) |\n" }
        if let c = constructor, !c.isEmpty { md += "| 施工 | \(c) |\n" }

        if managementFee != nil || repairReserveFund != nil || repairFundOnetime != nil {
            md += "\n## ランニングコスト\n\n"
            md += "| 項目 | 金額 |\n|---|---|\n"
            if let fee = managementFee { md += "| 管理費 | \(fee.formatted())円/月 |\n" }
            if let fund = repairReserveFund { md += "| 修繕積立金 | \(fund.formatted())円/月 |\n" }
            if let total = monthlyTotal { md += "| 合計（管理費+修繕積立金） | \(total.formatted())円/月 |\n" }
            if repairFundOnetime != nil { md += "| 修繕積立基金（一時金） | \(repairFundOnetimeDisplay) |\n" }
        }

        // 掲載状況（事実）
        let history = parsedPriceHistory
        if history.count > 1 || firstSeenAt != nil || competingListingsCount != nil {
            md += "\n## 掲載状況\n\n"
            if let days = daysOnMarket { md += "- **掲載日数**: \(days)日\n" }
            if let comp = competingListingsCount { md += "- **同一マンション内の売出数**: \(comp)件\n" }
            if history.count > 1 {
                md += "- **価格変動履歴**:\n"
                for entry in history {
                    if let p = entry.priceMan {
                        md += "  - \(entry.date): \(Self.formatPriceCompact(p))\n"
                    }
                }
            }
        }

        if hasCommuteInfo {
            md += "\n## 通勤時間\n\n"
            if let v2 = parsedCommuteInfoV2 {
                if let pg = v2.offices.playground {
                    let station = pg.selectedStation?.name ?? "駅未設定"
                    md += "- **Playground株式会社**: \(pg.representativeMinutes)分（レンジ \(pg.rangeDisplay) / \(station) ベース）\n"
                }
                if let m3 = v2.offices.m3career {
                    let station = m3.selectedStation?.name ?? "駅未設定"
                    md += "- **エムスリーキャリア株式会社**: \(m3.representativeMinutes)分（レンジ \(m3.rangeDisplay) / \(station) ベース）\n"
                }
            } else {
                let ci = parsedCommuteInfo
                if let pg = ci.playground {
                    md += "- **Playground株式会社**: \(pg.minutes)分（\(pg.summary)）\n"
                }
                if let m3 = ci.m3career {
                    md += "- **エムスリーキャリア株式会社**: \(m3.minutes)分（\(m3.summary)）\n"
                }
            }
        }

        if hasHazardData {
            let hd = parsedHazardData
            md += "\n## ハザード情報\n\n"
            md += "> 出典: 国土地理院ハザードマップ、東京都建物倒壊危険度調査\n\n"
            md += "| リスク | 該当 |\n|---|---|\n"
            md += "| 洪水浸水 | \(hd.flood ? "⚠️ あり" : "✅ なし") |\n"
            md += "| 土砂災害 | \(hd.sediment ? "⚠️ あり" : "✅ なし") |\n"
            md += "| 高潮浸水 | \(hd.stormSurge ? "⚠️ あり" : "✅ なし") |\n"
            md += "| 津波浸水 | \(hd.tsunami ? "⚠️ あり" : "✅ なし") |\n"
            md += "| 液状化 | \(hd.liquefaction ? "⚠️ あり" : "✅ なし") |\n"
            md += "| 内水浸水 | \(hd.inlandWater ? "⚠️ あり" : "✅ なし") |\n"
            if hd.buildingCollapse > 0 || hd.fire > 0 || hd.combined > 0 {
                md += "| 建物倒壊危険度 | ランク\(hd.buildingCollapse) |\n"
                md += "| 火災危険度 | ランク\(hd.fire) |\n"
                md += "| 総合危険度 | ランク\(hd.combined) |\n"
            }
        }

        if let pop = parsedPopulationData {
            md += "\n## エリア人口動態（\(pop.ward)）\n\n"
            md += "> 出典: e-Stat（総務省統計局）\n\n"
            md += "- **人口**: \(pop.populationDisplay)\n"
            md += "- **世帯数**: \(pop.householdsDisplay)\n"
            if let yoy = pop.popChange1yrPct { md += "- **前年比**: \(String(format: "%+.1f%%", yoy))\n" }
            if let y5 = pop.popChange5yrPct { md += "- **5年変動率**: \(String(format: "%+.1f%%", y5))\n" }
        }

        if let market = parsedMarketData {
            md += "\n## 成約相場（\(market.ward)）\n\n"
            md += "> 出典: 不動産情報ライブラリ（国土交通省）。成約価格ベース。\n\n"
            let tsuboPrice = Double(market.wardMedianM2Price) / 10000.0 * 3.30578
            md += "- **区中央値 坪単価**: \(String(format: "%.1f万/坪", tsuboPrice))（サンプル数: \(market.sampleCount)件）\n"
            if let yoy = market.yoyChangePct { md += "- **前年比**: \(String(format: "%+.1f%%", yoy))\n" }
            md += "- **トレンド**: \(market.trendDisplay)\n"
        }

        // 内見メモ・チェックリスト
        let comments = parsedComments
        if !comments.isEmpty {
            md += "\n## 内見メモ・コメント\n\n"
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            for c in comments {
                md += "- **\(c.authorName)**（\(formatter.string(from: c.createdAt))）: \(c.text)\n"
            }
        }

        let checklist = parsedChecklist
        if !checklist.isEmpty {
            md += "\n## 内見チェックリスト\n\n"
            for item in checklist {
                let mark = item.isChecked ? "✅" : "⬜"
                md += "- \(mark) \(item.label)"
                if let note = item.note, !note.isEmpty { md += "（\(note)）" }
                md += "\n"
            }
        }

        // ── 参考情報（第三者サービスの分析データ） ──

        let hasReferenceData = hasSumaiSurfinData || listingScore != nil
        if hasReferenceData {
            md += "\n---\n\n"
            md += "## 参考情報（第三者による分析データ）\n\n"
            md += "> ⚠️ 以下は外部サービスの独自モデルやアプリ内スコアリングによる分析値です。\n"
            md += "> 正確性は保証されません。事実情報に基づくあなた自身の分析を優先してください。\n\n"

            if hasSumaiSurfinData {
                md += "### 住まいサーフィン（sumai-surfin.com）\n\n"
                md += "住まいサーフィンは沖有人氏が代表を務める不動産情報サイトで、"
                md += "独自モデルに基づくマンション評価を提供しています。\n\n"

                if let profit = ssProfitPct {
                    md += "- **沖式儲かる確率**: \(profit)%\n"
                    md += "  - 算出根拠: 過去の売出価格と成約価格の乖離率等に基づく独自モデル\n"
                }
                if let judgment = computedPriceJudgment {
                    md += "- **割安判定**: \(judgment)\n"
                    if !isShinchiku {
                        if let oki = ssOkiPrice70m2 {
                            md += "  - 算出根拠: 沖式中古時価（70㎡換算 \(oki)万円）と販売価格の比較"
                            if let okiArea = ssOkiPriceForArea {
                                md += "。実面積換算では\(okiArea)万円"
                            }
                            md += "\n"
                        }
                    } else {
                        if let disc = ssM2Discount {
                            let tsuboDisc = String(format: "%.1f", Double(disc) * 3.30578)
                            md += "  - 算出根拠: 坪単価の乖離額 \(tsuboDisc)万円/坪（負値=割安、正値=割高）\n"
                        }
                    }
                }
                if let rate = ssAppreciationRate {
                    md += "- **中古値上がり率**: \(String(format: "%.1f", rate))%\n"
                    md += "  - 算出根拠: 新築分譲時の価格と現在の中古時価の比較による変動率\n"
                }
                if let stRank = ssStationRank { md += "- **駅ランキング**: \(stRank)\n" }
                if let wdRank = ssWardRank { md += "- **区ランキング**: \(wdRank)\n" }
                if let fav = ssFavoriteCount { md += "- **サイト内お気に入り数**: \(fav)\n" }
                if let pj = ssPurchaseJudgment {
                    md += "- **購入判定**: \(pj)\n"
                    md += "  - 算出根拠: 儲かる確率・値上がり率・立地等を総合した住まいサーフィン独自の判定\n"
                }
            }

            if listingScore != nil {
                md += "\n### アプリ内投資スコア\n\n"
                md += "当アプリが独自に算出した総合スコアです。以下の要素を重み付けして合算しています。\n\n"

                if let score = listingScore { md += "- **総合スコア**: \(score)/100\n\n" }

                let breakdown = scoreBreakdown
                if !breakdown.isEmpty {
                    md += "| 評価軸 | スコア | 重み | 根拠 |\n|---|---|---|---|\n"
                    for comp in breakdown {
                        md += "| \(comp.label) | \(comp.score)/100 | ×\(comp.weight) | \(comp.detail) |\n"
                    }
                    md += "\n"
                }
                md += "> スコアは価格妥当性（住まいサーフィン+成約相場）、再販流動性（総戸数・徒歩・面積・エリア）、"
                md += "値上がり率、儲かる確率、ハザードリスク数、通勤時間、人口動態を入力とした重み付き平均です。\n"
            }
        }

        md += "\n## リンク\n\n"
        md += "- [掲載元](\(url))\n"
        if let ssURL = ssSumaiSurfinURL { md += "- [住まいサーフィン](\(ssURL))\n" }

        return md
    }

    /// 管理費＋修繕積立金の月額合計
    private var monthlyTotal: Int? {
        guard managementFee != nil || repairReserveFund != nil else { return nil }
        return (managementFee ?? 0) + (repairReserveFund ?? 0)
    }

    /// 他の候補物件の概要を含めた AI 相談用プロンプトを生成する（意思決定型）
    func toAIConsultationPrompt(otherCandidates: [Listing], buyerProfile: BuyerProfile = .empty) -> String {
        let buildingName = name
        let addr = ssAddress ?? address ?? ""
        let primaryStation = parsedStations.first

        var prompt = """
        以下の\(isShinchiku ? "新築" : "中古")マンションについて、**「結論、この物件は私たちにとって買いかどうか」** を不動産購入エージェントの立場で総合判断してください。

        ## あなたの役割
        - 不動産購入の第三者エージェント（投資家目線 + 生活者目線の両立）
        - **最重要任務**: 個別スコアや単一パラメータの説明ではなく、複合的な視点でメリット・デメリットを統合し「買いかどうか」の結論を出すこと
        - すべての物件にはトレードオフがある前提で、この家族にとってそのトレードオフが許容範囲かを判断する
        - 出口での資産性（7-13年後に売却時に損しないか）は判断要素の一つとして組み込む
        - スクレイピングで取得できない情報（街の空気感、沿線カルチャー、学区の評判、コミュニティ）を積極的にリサーチし判断材料にする
        - 必ず**購入推奨度（★5段階）**と**具体的なアクション**を提示すること

        """

        let profileSection = buyerProfile.toMarkdownSection()
        if !profileSection.isEmpty {
            prompt += profileSection + "\n"
        }

        let floorPlans = parsedFloorPlanImages
        if !floorPlans.isEmpty {
            prompt += "## 間取り図の確認\n"
            prompt += "間取り図の画像を別途添付します。添付画像を分析し、家族計画（子ども3人）に照らした実用性を評価してください。\n\n"
        }

        prompt += "## 相談対象の物件\n\n"
        prompt += toMarkdown()

        if ssSimStandard10yr != nil || ssLoanBalance10yr != nil {
            prompt += "\n### 10年後シミュレーション（住まいサーフィン参考値）\n\n"
            prompt += "> ⚠️ 独自モデルによる予測値。あなた自身の分析と照合してください。\n\n"
            if let base = ssSimBasePrice { prompt += "- 基準価格: \(base)万円\n" }
            if let best10 = ssSimBest10yr { prompt += "- 10年後（楽観）: \(best10)万円\n" }
            if let std10 = ssSimStandard10yr { prompt += "- 10年後（標準）: \(std10)万円\n" }
            if let worst10 = ssSimWorst10yr { prompt += "- 10年後（悲観）: \(worst10)万円\n" }
            if let loan10 = ssLoanBalance10yr { prompt += "- 10年後ローン残高: \(loan10)万円\n" }
            prompt += "\n"
        }

        if !otherCandidates.isEmpty {
            prompt += "\n---\n\n## 比較検討中の物件\n\n"
            prompt += "以下の物件も並行して検討しています。相談対象と比較して「どちらがこの家族に合うか」も判断してください。\n\n"
            prompt += "| 項目 |"
            for (i, _) in otherCandidates.enumerated() { prompt += " 候補\(i + 1) |" }
            prompt += "\n|---|"
            for _ in otherCandidates { prompt += "---|" }
            prompt += "\n| 物件名 |"
            for c in otherCandidates { prompt += " \(c.name) |" }
            prompt += "\n| 価格 |"
            for c in otherCandidates { prompt += " \(c.priceDisplay) |" }
            prompt += "\n| 面積 |"
            for c in otherCandidates {
                prompt += " \(c.areaM2.map { String(format: "%.1f㎡", $0) } ?? "—") |"
            }
            prompt += "\n| 間取り |"
            for c in otherCandidates { prompt += " \(c.layout ?? "—") |" }
            prompt += "\n| 住所 |"
            for c in otherCandidates { prompt += " \(c.ssAddress ?? c.address ?? "—") |" }
            prompt += "\n| 最寄駅 |"
            for c in otherCandidates { prompt += " \(c.primaryStationDisplay) |" }
            prompt += "\n| 築年 |"
            for c in otherCandidates { prompt += " \(c.builtAgeDisplay) |" }
            prompt += "\n"
        }

        let stationName = primaryStation?.name ?? "最寄駅"
        let lineName = primaryStation?.line ?? "路線"

        prompt += """

        ---

        ## 自律リサーチ指示（重要）

        **必ず Web 検索を行い**、提供データだけで判断せず以下を自律的にリサーチしてから回答してください。

        ### 【必須】回答前に必ず実施
        1. **マンション名「\(buildingName)」で検索** — 分譲時情報・管理会社・大規模修繕履歴・構造
        2. **成約相場** — 同一駅・同一エリアの直近成約事例（価格推移・坪単価）
        3. **ハザード**（⚠️ **必ず自治体の公式ハザードマップで上書き確認**すること）
           - 洪水浸水想定・液状化・地震危険度を自治体公式サイトから定量値取得
           - ユーザー提供データと差異がある場合は自治体情報を採用し差異を明示

        ### 【必須】生活適合性リサーチ
        4. **沿線カルチャー・住民層** — 「\(lineName) 住みやすさ ファミリー」で検索。沿線の雰囲気（落ち着き/活気/混雑度/帰宅ラッシュ）をまとめる
        5. **駅・街の生活感** — 「\(stationName) 子育て 住みやすさ」で検索
           - スーパー・ドラッグストアの充実度、保育園・小児科・公園の近さと質
           - 飲食店や商店街の雰囲気、夜道の安全性
        6. **学区情報** — 「\(addr) 学区」「小学校 評判」で検索
           - 通学区の小学校名・距離・評判、保育園の入りやすさ
        7. **休日の過ごし方** — 「\(stationName) 子連れスポット 公園」で検索
           - 徒歩圏の公園（広さ・遊具）、雨の日の選択肢、週末お出かけアクセス
        8. **コミュニティ** — 「\(buildingName) 口コミ 住民」で検索
           - マンション住民層の推定（ファミリー比率）、近隣の子育て世帯密度

        ### 【推奨】余裕があれば
        9. **管理会社の評判** — 管理会社名で口コミ検索
        10. **金利動向** — 現在の住宅ローン金利と見通し

        ## 重要ルール

        ### 判断の姿勢（最重要）
        - **個別スコアを並べるな**。スコアは物件詳細画面で見られる。あなたの仕事は「それらを統合して結論を出す」こと
        - メリット・デメリットは両方あることが前提。その上で**「総合的に買いか」を1つの結論として断言**する
        - 「〇〇は良いが△△が悪い」で終わるのは分析であって判断ではない。最後に「だから買い/見送り」まで言い切ること

        ### 家族計画と保有年数の整合チェック（必須）
        - **間取り・広さの耐用年数**: 子ども3人計画に対して何年目で手狭になるか具体的に示す
        - **住み替えタイミングの妥当性**: 7〜13年後住み替えと子の進学時期に矛盾がないか
        - **売却タイミングの有利/不利**: 家族構成変化で売却を急ぐリスクがないか

        ### 情報源ルール
        - 一次情報 > 二次情報 > 口コミの優先順位
        - 確認できない事項は「未確認」と明示し、確認に必要な資料名を列挙

        """

        prompt += "## 必須出力フォーマット\n\n"
        prompt += """
        まず冒頭に以下を示してください：

        ```
        購入推奨度: ★★★★☆（5段階）
        結論: 買い / 条件付き買い（指値○○万円以下なら） / 見送り
        一言: 「〇〇という弱点はあるが、△△がこの家族には決定的。買い。」
        ```

        そのうえで以下を順番に回答：

        1. **総合判断の根拠**
           - メリットとデメリットを並列し、「この家族に照らしてどちらが勝るか」を論じる
           - 出口の資産性も判断の一要素として組み込む（独立セクションではなく根拠の中で言及）
           - 間取り×家族計画の耐用年数を具体的に示す（「3LDK 65㎡で子ども3人は○年目で限界」等）

        2. **この家族にとっての具体的フィット/ミスマッチ**
           - 買い手プロファイルの各項目（通勤・子育て・街の好み・NG条件）と物件を紐づけて評価
           - 7年後の生活を具体的にイメージして描写

        3. **街・沿線の生活実感**（リサーチ結果に基づく）
           - 沿線カルチャーとこの家族への適合度
           - 日常の買い物・通勤の質・学区・休日の過ごし方
           - 治安・夜道の安全性

        4. **資産性の守り確認**
           - 妥当価格レンジ（○○万円〜○○万円）
           - 7/10/13年後の出口試算（楽観・中立・悲観）
           - 致命的リスクの有無

        5. **アクション提案**
           - 買う場合: 指値金額・交渉戦略・内覧確認事項
           - 見送る場合: 何が改善されれば検討対象になるか

        """

        if !floorPlans.isEmpty {
            prompt += "6. **間取り分析** — 家族計画に照らした実用性（子ども部屋確保可能時期等）\n\n"
        }

        if !otherCandidates.isEmpty {
            prompt += "7. **比較検討物件との相対評価** — この家族にとってどちらがフィットするか、トレードオフ構造を明示\n\n"
        }

        prompt += "8. **未確認事項・仲介確認質問** — 確認すべき情報と資料名、内覧時の質問リスト\n"

        return prompt
    }

    // MARK: - 複数物件 AI 比較プロンプト

    /// 選択した複数物件を対等に比較する AI プロンプトを生成する。
    /// 各物件のフル Markdown を含み、総合ランキング・比較表を出力指示する。
    static func toAIComparisonPrompt(listings: [Listing], buyerProfile: BuyerProfile = .empty) -> String {
        let count = listings.count
        let hasShinchiku = listings.contains(where: \.isShinchiku)
        let hasChuko = listings.contains(where: { !$0.isShinchiku })
        let typeLabel: String = {
            if hasShinchiku && hasChuko { return "新築・中古" }
            if hasShinchiku { return "新築" }
            return "中古"
        }()

        var prompt = """
        以下の\(typeLabel)マンション \(count) 件について、**「この家族にとってどれを買うべきか」の購入推奨ランキング** を作成してください。

        ## あなたの役割
        - 不動産購入の第三者エージェント
        - **最重要任務**: 個別スコアの横並び比較ではなく、「この家族にとってどの物件が最もフィットするか」を明確な順位で示す
        - 物件間のトレードオフ構造（何を得て何を失うか）を明示し、この家族にとってどのトレードオフが許容範囲かを判断する
        - 資産性は判断要素の一つ。「資産性推奨」と「生活推奨」が異なる場合はそれを明示した上で最終推奨を1つに絞る
        - スクレイピングで取得できない情報（街の空気感、沿線カルチャー、学区、コミュニティ）も積極的にリサーチ

        """

        let profileSection = buyerProfile.toMarkdownSection()
        if !profileSection.isEmpty {
            prompt += profileSection + "\n"
        }

        for (i, listing) in listings.enumerated() {
            prompt += "\n---\n\n"
            prompt += "## 物件\(i + 1)\n\n"
            prompt += listing.toMarkdown()

            if listing.ssSimStandard10yr != nil || listing.ssLoanBalance10yr != nil {
                prompt += "\n### 10年後シミュレーション（参考値）\n\n"
                if let base = listing.ssSimBasePrice { prompt += "- 基準価格: \(base)万円\n" }
                if let best10 = listing.ssSimBest10yr { prompt += "- 10年後（楽観）: \(best10)万円\n" }
                if let std10 = listing.ssSimStandard10yr { prompt += "- 10年後（標準）: \(std10)万円\n" }
                if let worst10 = listing.ssSimWorst10yr { prompt += "- 10年後（悲観）: \(worst10)万円\n" }
                if let loan10 = listing.ssLoanBalance10yr { prompt += "- 10年後ローン残高: \(loan10)万円\n" }
                prompt += "\n"
            }
        }

        let buildingNames = listings.map(\.name)
        let stations = listings.compactMap { $0.parsedStations.first }

        prompt += """

        ---

        ## 自律リサーチ指示（重要）

        **必ず Web 検索を行い**、各物件について以下をリサーチしてから回答してください。

        ### 【必須】各物件について実施
        1. **マンション名で検索** — 分譲時情報・管理会社・大規模修繕履歴

        """
        for bname in buildingNames {
            prompt += "   - 「\(bname)」\n"
        }

        prompt += """
        2. **成約相場** — 各物件の同一駅・同エリアの直近成約事例
        3. **ハザード** — 自治体公式ハザードマップで確認

        ### 【必須】生活適合性リサーチ（各物件の駅・エリアについて）

        """
        for st in stations {
            prompt += "4. 「\(st.line ?? "") \(st.name ?? "") 住みやすさ ファミリー」で沿線・駅の生活感を調査\n"
            prompt += "5. 「\(st.name ?? "") 子育て 学区 公園」で子育て環境を調査\n"
        }

        prompt += """

        ## 重要ルール

        ### 判断の姿勢（最重要）
        - **個別スコアの横並び表で終わらない**。スコアは物件詳細画面で見られる。あなたの仕事は「統合して順位を付ける」こと
        - 全ての物件にトレードオフがある前提で、「この家族にとってどのトレードオフが最も許容できるか」を判断する
        - 最後に**明確な1位**を示す。「甲乙つけがたい」は禁止。迷っても順位を付ける

        ### 家族計画チェック（必須）
        - 各物件について: 間取り×子ども3人で何年目に手狭になるか
        - 住み替えタイミング（7-13年後）と子の進学時期の整合性

        ### 情報源ルール
        - 一次情報 > 二次情報 > 口コミ
        - 確認できない事項は「未確認」と明示

        """

        prompt += "## 必須出力フォーマット\n\n"
        prompt += """
        まず冒頭に以下を示してください：

        ```
        【購入推奨ランキング】

        """
        for i in 1...count {
            prompt += "        \(i)位: 物件名 ★★★★☆ — 「一言理由」\n"
        }
        prompt += """
        ```
        ※全て見送りの場合はその旨を明記し、より適した条件の物件像を提示

        そのうえで以下を順番に回答：

        1. **ランキングの根拠**
           - 各物件のメリット・デメリットを踏まえ、「この家族の状況」に紐づけて順位の理由を説明
           - 「物件Aは狭いが、立地の優位性が居住性の犠牲を上回る。なぜなら…」のように複合判断を示す

        2. **トレードオフの可視化**
           - 物件間で「何を得て何を失うか」の構造を明示
           - この家族の優先順位に照らして、どのトレードオフが許容範囲かを判断

        3. **暮らしの比較**（リサーチ結果に基づく）
           - 各物件の沿線・駅の性格を対比
           - 子育てしやすさ・通勤の質・休日の過ごし方の具体的な差異

        4. **資産性の横断比較**
           - 各物件の妥当価格レンジと出口試算
           - 「資産性で選ぶならこれ、生活で選ぶならこれ」が異なる場合はそれを明示

        5. **最終アクション**
           - 1位物件への具体的アクション（指値金額・スケジュール）
           - 「1位と2位で迷う場合」の判断基準

        6. **未確認事項・仲介確認質問**

        """

        return prompt
    }
}
