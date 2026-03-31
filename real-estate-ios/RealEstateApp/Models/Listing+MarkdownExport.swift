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
            let ci = parsedCommuteInfo
            md += "\n## 通勤時間\n\n"
            if let pg = ci.playground {
                md += "- **Playground株式会社**: \(pg.minutes)分（\(pg.summary)）\n"
            }
            if let m3 = ci.m3career {
                md += "- **エムスリーキャリア株式会社**: \(m3.minutes)分（\(m3.summary)）\n"
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

        var prompt = """
        以下の\(isShinchiku ? "新築" : "中古")マンションについて、**7〜13年（中心10年）の保有・住み替え前提**で「買い / 指値前提で検討 / 見送り」を判断してください。
        単なる物件紹介や調査メモではなく、**購入判断メモ**として分析してください。

        ## あなたの役割
        - 7〜13年（中心10年）保有・住み替え前提での\(isShinchiku ? "新築" : "中古")マンション購入のプロフェッショナルアドバイザー
        - 市場動向・価格妥当性・将来の資産価値・リスク要因を多角的に分析
        - 見落としがちな観点（管理組合の健全性、大規模修繕の時期、周辺再開発計画、金利動向など）を指摘
        - **実需と資産性の両立**を重視し、7〜13年後に売却する前提で出口価格と残債のバランスを重視
        - 必ず**妥当価格レンジ**と**買付上限価格**を提示すること

        """

        // 買い手条件
        let profileSection = buyerProfile.toMarkdownSection()
        if !profileSection.isEmpty {
            prompt += profileSection + "\n"
        }

        let floorPlans = parsedFloorPlanImages
        if !floorPlans.isEmpty {
            prompt += "## 間取り図の確認\n"
            prompt += "間取り図の画像を別途添付します。添付画像を分析し、"
            prompt += "間取りの特徴・生活動線・収納・採光・改善点をコメントしてください。\n\n"
        }

        prompt += "## 相談対象の物件\n\n"
        prompt += toMarkdown()

        // 住まいサーフィンのシミュレーションデータがあれば追記
        if ssSimStandard10yr != nil || ssLoanBalance10yr != nil {
            prompt += "\n### 10年後シミュレーション（住まいサーフィン参考値）\n\n"
            prompt += "> ⚠️ 住まいサーフィンの独自モデルによる予測値です。あなた自身の分析と照合してください。\n\n"
            if let base = ssSimBasePrice { prompt += "- シミュレーション基準価格: \(base)万円\n" }
            if let best10 = ssSimBest10yr { prompt += "- 10年後（楽観）: \(best10)万円\n" }
            if let std10 = ssSimStandard10yr { prompt += "- 10年後（標準）: \(std10)万円\n" }
            if let worst10 = ssSimWorst10yr { prompt += "- 10年後（悲観）: \(worst10)万円\n" }
            if let loan10 = ssLoanBalance10yr { prompt += "- 10年後ローン残高: \(loan10)万円\n" }
            prompt += "\n"
        }

        if !otherCandidates.isEmpty {
            prompt += "\n---\n\n## 比較検討中の物件\n\n"
            prompt += "以下の物件も並行して検討しています。\n"
            prompt += "**比較物件の調査深度**: 比較物件についても **相談対象と同等のフルリサーチ** を実施してください。"
            prompt += "各物件に対して自律リサーチ指示（マンション名検索・成約相場・ハザード等）を同じ粒度で行い、"
            prompt += "相談対象との相対評価（価格・資産性・利便性・リスクの4軸）を根拠付きでコメントしてください。\n\n"
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

        prompt += """

        ---

        ## 自律リサーチ指示（重要）

        以下の物件情報を読んだうえで、**必ず Web 検索を行い**、最新かつ正確な情報を自分で取得してください。
        提供データだけで判断せず、以下を自律的にリサーチしてから回答してください。

        ### 【必須】回答前に必ず実施
        1. **マンション名「\(buildingName)」で検索** — 分譲時情報・管理会社・大規模修繕履歴・構造
        2. **住所「\(addr)」周辺** — 再開発計画・治安・学区・新築供給予定（競合リスク）
        3. **成約相場** — 同一駅・同一エリアの直近成約事例（価格推移・坪単価）
        4. **ハザード**（⚠️ ユーザー提供値をそのまま使わず、**必ず自治体の公式ハザードマップで上書き確認**すること）
           - 洪水浸水想定区域・内水氾濫・液状化・地震危険度を **自治体公式サイトの一次情報** から定量値で取得
           - ユーザー提供のハザードデータと自治体情報に差異がある場合は、**自治体情報を採用し差異を明示**
           - 確認した自治体ハザードマップの URL を情報源として記載

        ### 【推奨】余裕があれば実施
        5. **マンション口コミ** — 「マンションコミュニティ」「マンションノート」等で「\(buildingName)」を検索
        6. **管理会社の評判** — 管理会社名で口コミサイト検索（行政処分・問題事案も）
        7. **金利動向** — 現在の住宅ローン金利と今後の見通し

        ## 重要ルール

        ### 情報源の重みづけ（厳守）
        情報源は以下の優先順位で扱ってください：
        1. **一次情報**（公的機関・公式資料・売主/管理会社/仲介の公式情報） — 最優先
        2. **二次情報**（不動産ポータル・仲介掲載情報） — 信頼度高
        3. **口コミ情報**（掲示板・レビューサイト） — 補助情報として扱い、一次情報と矛盾する場合は一次情報を優先

        ### 未確認情報の扱い（厳守）
        **公開 Web で確認できない事項は推測せず、「未確認」と明示してください。**
        そのうえで、確認に必要な資料名を列挙してください（例: 重要事項調査報告書、長期修繕計画、総会議事録、管理規約、修繕履歴 等）。

        ### 家族計画と保有年数の整合チェック（必須）
        購入者プロフィールに「子ども予定」「住み替え理由」「返済期間」がある場合、以下を必ず検証してください：
        - **間取り・広さの耐用年数**: 家族が最大人数に達する時期と、この物件の間取り・広さで生活が成り立つ年数を照合
        - **住み替えタイミングの妥当性**: 「7〜13年後住み替え前提」と子どもの進学時期（小学校入学など）に矛盾がないか
        - **売却タイミングの有利/不利**: 家族構成の変化によって売却を急ぐリスク（＝足元を見られる）がないか
        - この整合チェックの結果は **結論（項目1）** の根拠に必ず反映すること

        ### 「参考情報」セクションの扱い
        - 「参考情報」セクションは第三者サービスの独自モデルやアプリ内スコアリングによる分析値です
        - 正確性が保証されないため、あなた自身のリサーチ結果を優先してください
        - 参考情報と事実情報の間に矛盾がある場合は明示してください

        """

        prompt += "## 必須出力フォーマット\n\n"
        prompt += "まず冒頭に **3行の結論サマリー** を示したうえで、以下を順番に回答してください。\n\n"
        prompt += "1. **結論**（買い / 指値前提で検討 / 見送り）— 根拠を箇条書きで\n"
        prompt += "2. **妥当価格レンジ** — 〇〇万円〜〇〇万円\n"
        prompt += "3. **買付上限価格** — 〇〇万円（これ以上なら見送り）\n"
        prompt += "4. **出口試算（7年・10年・13年の3時点）**（以下の前提を明示して計算すること）\n"
        prompt += "   - **前提条件**:\n"
        prompt += "     - 売却費率: **5.5%**（仲介手数料3%+6万円+税 + 登記費用等）\n"
        prompt += "     - 金利シナリオ: 楽観=現行金利維持、中立=+0.5%、悲観=+1.0%（変動金利の場合。保有期間中のトータル上昇幅）\n"
        prompt += "     - 初期コスト: ローン手数料（融資事務手数料 or 保証料）・登記費用・火災保険を含めた購入総額を起点とすること\n"
        prompt += "   - **7年後・10年後・13年後** それぞれについて、楽観・中立・悲観の3シナリオで想定売却価格を提示\n"

        if !buyerProfile.isEmpty {
            prompt += "   - 各時点での残債試算（金利上昇シナリオ別）\n"
            prompt += "   - 売却諸費用を加味した手取り試算\n"
            prompt += "   - 損益分岐売却価格（初期コスト込みで算出）\n"
        }

        prompt += "5. **価格妥当性**（以下の **2軸** を分けて評価すること）\n"
        prompt += "   - **a. 区中央値との比較** — 所在区の中古マンション坪単価中央値と本物件の坪単価を比較。区全体の水準感を把握する目的\n"
        prompt += "   - **b. 同駅・同条件比較** — 最寄駅が同一かつ築年帯（±8年）・面積帯（±10㎡）が近い直近成約事例と坪単価を比較。実勢相場との乖離を定量的に示すこと\n"
        prompt += "6. **資産価値** — 周辺再開発・人口動態を踏まえた評価\n"
        prompt += "7. **リスク要因** — 管理・修繕・ハザード・法的リスク・競合供給\n"
        prompt += "8. **口コミ・住み心地** — 掲示板・管理会社評判の要約（情報源を明記）\n"
        prompt += "9. **生活面の評価** — 通勤・買い物・子育て・医療・治安\n"

        if !floorPlans.isEmpty {
            prompt += "10. **間取り分析** — 生活動線・収納・採光の評価、改善点\n"
        }

        if !otherCandidates.isEmpty {
            prompt += "11. **比較** — 価格・資産性・利便性・リスクの4軸で比較表を作成し推奨順位\n"
        }

        prompt += "12. **仲介に確認すべき質問** — 内覧・交渉時に聞くべき具体的な質問リスト\n"
        prompt += "13. **未確認事項** — 確認できなかった情報と、その確認に必要な資料名\n"

        prompt += "\n---\n\n"
        prompt += "## 回答末尾に必ず追加してください\n\n"
        prompt += "回答の最後に以下を追記してください：\n\n"
        prompt += "### 不足情報・追加で提供してほしいデータ\n"
        prompt += "より精度の高い判断のために、追加で提供してほしい情報があれば具体的に列挙してください。\n\n"
        prompt += "### このプロンプトへのフィードバック\n"
        prompt += "このプロンプト自体の改善点（構成・指示の明確さ・不足している観点・無駄な指示など）があれば率直に指摘してください。\n"

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
        以下の\(typeLabel)マンション \(count) 件を**対等に比較**し、**10年後住み替え前提**での推奨順位を判断してください。
        特定の物件を「主」として扱わず、全物件をフラットに分析してください。

        ## あなたの役割
        - 10年住み替え前提でのマンション購入のプロフェッショナルアドバイザー
        - 複数物件を**同一基準**で横断比較し、客観的な優劣を定量・定性の両面で示す
        - 市場動向・価格妥当性・将来の資産価値・リスク要因を多角的に分析
        - **実需と資産性の両立**を重視し、10年後に売却する前提で出口価格と残債のバランスを重視
        - 必ず各物件の**妥当価格レンジ**と**買付上限価格**を提示すること

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
                prompt += "\n### 10年後シミュレーション（住まいサーフィン参考値）\n\n"
                prompt += "> 住まいサーフィンの独自モデルによる予測値です。あなた自身の分析と照合してください。\n\n"
                if let base = listing.ssSimBasePrice { prompt += "- シミュレーション基準価格: \(base)万円\n" }
                if let best10 = listing.ssSimBest10yr { prompt += "- 10年後（楽観）: \(best10)万円\n" }
                if let std10 = listing.ssSimStandard10yr { prompt += "- 10年後（標準）: \(std10)万円\n" }
                if let worst10 = listing.ssSimWorst10yr { prompt += "- 10年後（悲観）: \(worst10)万円\n" }
                if let loan10 = listing.ssLoanBalance10yr { prompt += "- 10年後ローン残高: \(loan10)万円\n" }
                prompt += "\n"
            }
        }

        let buildingNames = listings.map(\.name)
        let addresses = listings.compactMap { $0.ssAddress ?? $0.address }

        prompt += """

        ---

        ## 自律リサーチ指示（重要）

        以下の物件情報を読んだうえで、**必ず Web 検索を行い**、最新かつ正確な情報を自分で取得してください。
        提供データだけで判断せず、以下を自律的にリサーチしてから回答してください。

        ### 【必須】回答前に各物件について実施
        1. **マンション名で検索** — 分譲時情報・管理会社・大規模修繕履歴・構造

        """
        for name in buildingNames {
            prompt += "   - 「\(name)」\n"
        }

        prompt += "2. **住所周辺** — 再開発計画・治安・学区・新築供給予定（競合リスク）\n"
        for addr in addresses {
            prompt += "   - 「\(addr)」\n"
        }

        prompt += """
        3. **成約相場** — 各物件の同一駅・同一エリアの直近成約事例（価格推移・坪単価）
        4. **ハザード**（⚠️ ユーザー提供値をそのまま使わず、**必ず自治体の公式ハザードマップで上書き確認**すること）
           - 洪水浸水想定区域・内水氾濫・液状化・地震危険度を **自治体公式サイトの一次情報** から定量値で取得
           - ユーザー提供のハザードデータと自治体情報に差異がある場合は、**自治体情報を採用し差異を明示**

        ### 【推奨】余裕があれば実施
        5. **マンション口コミ** — 「マンションコミュニティ」「マンションノート」等で各物件を検索
        6. **管理会社の評判** — 管理会社名で口コミサイト検索
        7. **金利動向** — 現在の住宅ローン金利と今後の見通し

        ## 重要ルール

        ### 情報源の重みづけ（厳守）
        1. **一次情報**（公的機関・公式資料・売主/管理会社/仲介の公式情報） — 最優先
        2. **二次情報**（不動産ポータル・仲介掲載情報） — 信頼度高
        3. **口コミ情報**（掲示板・レビューサイト） — 補助情報として扱い、一次情報と矛盾する場合は一次情報を優先

        ### 未確認情報の扱い（厳守）
        **公開 Web で確認できない事項は推測せず、「未確認」と明示してください。**
        そのうえで、確認に必要な資料名を列挙してください。

        ### 「参考情報」セクションの扱い
        - 「参考情報」セクションは第三者サービスの独自モデルやアプリ内スコアリングによる分析値です
        - 正確性が保証されないため、あなた自身のリサーチ結果を優先してください
        - 参考情報と事実情報の間に矛盾がある場合は明示してください

        """

        if !buyerProfile.isEmpty {
            prompt += """
            ### 家族計画と保有年数の整合チェック（必須）
            購入者プロフィールに「子ども予定」「住み替え理由」「返済期間」がある場合、各物件について以下を検証してください：
            - **間取り・広さの耐用年数**: 家族が最大人数に達する時期と、物件の間取り・広さで生活が成り立つ年数を照合
            - **住み替えタイミングの妥当性**: 「10年後住み替え前提」と子どもの進学時期に矛盾がないか
            - **売却タイミングの有利/不利**: 家族構成の変化によって売却を急ぐリスクがないか

            """
        }

        prompt += "## 必須出力フォーマット\n\n"
        prompt += "まず冒頭に **3行の結論サマリー**（推奨物件とその理由）を示したうえで、以下を順番に回答してください。\n\n"
        prompt += "1. **総合ランキング** — 推奨順位を明示し、順位の根拠を箇条書きで\n"
        prompt += "2. **横断比較表** — 以下の軸で全物件を比較する表を作成\n"
        prompt += "   - 価格妥当性（坪単価・相場比較）\n"
        prompt += "   - 資産性（10年後の出口試算・騰落予測）\n"
        prompt += "   - 生活利便性（通勤・買い物・子育て・医療）\n"
        prompt += "   - リスク（ハザード・管理・修繕・法的リスク）\n"
        prompt += "   - 総合評価（S/A/B/C/D）\n"
        prompt += "3. **各物件の個別分析**（物件ごとに以下を記載）\n"
        prompt += "   - a. 妥当価格レンジ（〇〇万円〜〇〇万円）\n"
        prompt += "   - b. 買付上限価格（これ以上なら見送り）\n"
        prompt += "   - c. 10年後の出口試算（楽観・中立・悲観の3シナリオ）\n"
        prompt += "     - 前提: 売却費率5.5%、金利シナリオ: 楽観=現行維持、中立=+0.5%、悲観=+1.0%\n"

        if !buyerProfile.isEmpty {
            prompt += "     - 残債試算・手取り試算・損益分岐売却価格を含めること\n"
        }

        prompt += "   - d. 価格妥当性（区中央値比較 + 同駅・同条件比較）\n"
        prompt += "   - e. 資産価値（周辺再開発・人口動態）\n"
        prompt += "   - f. リスク要因（管理・修繕・ハザード・法的リスク・競合供給）\n"
        prompt += "   - g. 生活面の評価（通勤・買い物・子育て・医療・治安）\n"
        prompt += "4. **物件間の決定的な差異** — 判断を分ける最も重要なポイントを3つ以内で\n"
        prompt += "5. **仲介に確認すべき質問** — 各物件について内覧・交渉時に聞くべき質問リスト\n"
        prompt += "6. **未確認事項** — 確認できなかった情報と、その確認に必要な資料名\n"

        prompt += "\n---\n\n"
        prompt += "## 回答末尾に必ず追加してください\n\n"
        prompt += "### 不足情報・追加で提供してほしいデータ\n"
        prompt += "より精度の高い判断のために、追加で提供してほしい情報があれば具体的に列挙してください。\n\n"
        prompt += "### このプロンプトへのフィードバック\n"
        prompt += "このプロンプト自体の改善点があれば率直に指摘してください。\n"

        return prompt
    }
}
