//
//  MarketDataSectionView.swift
//  RealEstateApp
//
//  不動産情報ライブラリ（国土交通省）の成約価格データに基づく
//  相場比較・エリアトレンドセクション。
//

import SwiftUI
import Charts

// MARK: - メインセクション

struct MarketDataSectionView: View {
    let listing: Listing

    var body: some View {
        if let market = listing.parsedMarketData {
            VStack(alignment: .leading, spacing: 14) {
                // セクションヘッダー
                Label("成約相場との比較", systemImage: "building.2.fill")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)

                // ── 相場乖離率カード（区レベル段階的マッチング） ──
                priceComparisonCard(market)

                // ── エリア相場情報 ──
                areaInfoGrid(market)

                // ── 駅レベル比較 ──
                if let station = market.station {
                    Divider()
                    stationComparisonSection(station, ward: market.ward)
                }

                // ── 同一マンション候補の成約事例 ──
                if !market.sameBuildingTransactions.isEmpty {
                    Divider()
                    sameBuildingSection(market)
                }

                // ── m²単価推移チャート ──
                if market.yearlyM2Prices.count >= 2
                    || (market.station?.yearlyM2Prices.count ?? 0) >= 2
                    || market.quarterlyM2Prices.count >= 3
                    || (market.station?.quarterlyM2Prices.count ?? 0) >= 3
                {
                    Divider()
                    trendChartSection(market)
                }

                // フッター
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("出典: \(market.dataSource)（成約価格ベース）")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
        }
    }

    // MARK: - 相場乖離率カード

    @ViewBuilder
    private func priceComparisonCard(_ market: Listing.MarketData) -> some View {
        VStack(spacing: 10) {
            // メイン: 乖離率表示
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("掲載価格 vs 類似物件成約相場")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(market.priceRatioDisplay)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(priceRatioColor(market.priceRatio))
                }

                Spacer()

                // 差額
                if let _ = market.priceDiffMan {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("差額")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(market.priceDiffDisplay)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(priceDiffColor(market.priceDiffMan))
                    }
                }
            }

            // 補足: マッチ条件 + サンプル数
            HStack(spacing: 6) {
                // マッチ精度バッジ
                Text(market.matchTierLabel)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(matchTierBadgeColor(market.matchTier))
                    .clipShape(Capsule())

                Text("\(market.matchDescription)の成約\(market.sampleCount)件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(priceRatioBackgroundColor(market.priceRatio))
        )
    }

    // MARK: - エリア相場グリッド

    @ViewBuilder
    private func areaInfoGrid(_ market: Listing.MarketData) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ],
            spacing: 10
        ) {
            areaInfoCell(
                title: "類似物件相場",
                value: market.wardMedianM2PriceManDisplay,
                icon: "yensign.circle",
                subtitle: market.matchDescription
            )
            areaInfoCell(
                title: "\(market.ward)トレンド",
                value: market.trendDisplay,
                icon: market.trendIconName,
                color: trendColor(market.trend)
            )
            areaInfoCell(
                title: "\(market.ward)前年比",
                value: market.yoyDisplay,
                icon: "chart.line.uptrend.xyaxis",
                color: yoyColor(market.yoyChangePct)
            )
        }
    }

    @ViewBuilder
    private func areaInfoCell(
        title: String,
        value: String,
        icon: String,
        color: Color = .primary,
        subtitle: String? = nil
    ) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.systemGray6).opacity(0.5))
        )
    }

    // MARK: - 同一マンション候補の成約事例（間取り別サマリー）

    /// 間取り別に集計したサマリー
    private struct LayoutSummary: Identifiable {
        let id: String           // floorPlan
        let floorPlan: String
        let count: Int
        let avgPriceMan: Int
        let avgM2Price: Int
        let avgArea: Double
        let transactions: [Listing.MarketData.SameBuildingTransaction]
        let isMatchingLayout: Bool  // 閲覧中の物件と同じ間取りか

        var avgPriceDisplay: String {
            if avgPriceMan >= 10000 {
                return String(format: "%.1f億円", Double(avgPriceMan) / 10000.0)
            }
            return "\(avgPriceMan)万円"
        }

        var avgM2PriceManDisplay: String {
            String(format: "%.1f万/m²", Double(avgM2Price) / 10000.0)
        }
    }

    /// 成約事例を間取り別に集計
    private func buildLayoutSummaries(
        _ market: Listing.MarketData
    ) -> [LayoutSummary] {
        // 間取り別にグルーピング
        var grouped: [String: [Listing.MarketData.SameBuildingTransaction]] = [:]
        for tx in market.sameBuildingTransactions {
            let key = tx.floorPlan.isEmpty ? "不明" : tx.floorPlan
            grouped[key, default: []].append(tx)
        }

        let listingLayout = listing.layout ?? ""

        return grouped.map { floorPlan, txs in
            let avgPrice = txs.reduce(0) { $0 + $1.tradePriceMan } / txs.count
            let avgM2 = txs.reduce(0) { $0 + $1.m2Price } / txs.count
            let avgArea = txs.reduce(0.0) { $0 + $1.area } / Double(txs.count)
            // 間取りが一致するか（"3LDK" が含まれるかで判定）
            let isMatch = !listingLayout.isEmpty && floorPlan == listingLayout
            return LayoutSummary(
                id: floorPlan,
                floorPlan: floorPlan,
                count: txs.count,
                avgPriceMan: avgPrice,
                avgM2Price: avgM2,
                avgArea: avgArea,
                transactions: txs.sorted { $0.period > $1.period },
                isMatchingLayout: isMatch
            )
        }
        // 閲覧中の物件と同じ間取りを先頭に、あとは件数順
        .sorted { a, b in
            if a.isMatchingLayout != b.isMatchingLayout { return a.isMatchingLayout }
            return a.count > b.count
        }
    }

    @ViewBuilder
    private func sameBuildingSection(_ market: Listing.MarketData) -> some View {
        let summaries = buildLayoutSummaries(market)

        VStack(alignment: .leading, spacing: 10) {
            // ヘッダー
            HStack(spacing: 6) {
                Image(systemName: "building.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("同一マンション候補の成約事例")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(market.sameBuildingTransactions.count)件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // 間取り別サマリー（DisclosureGroup で明細展開）
            ForEach(summaries) { summary in
                layoutSummaryRow(summary)
            }

            // 注意書き
            Text("※ 同区・同町名・同築年・同構造で推定。同一棟を保証するものではありません")
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
    }

    @ViewBuilder
    private func layoutSummaryRow(_ summary: LayoutSummary) -> some View {
        DisclosureGroup {
            // 展開時: 個別の成約明細
            VStack(spacing: 4) {
                ForEach(
                    Array(summary.transactions.enumerated()),
                    id: \.offset
                ) { _, tx in
                    sameBuildingTransactionRow(tx)
                }
            }
            .padding(.top, 4)
        } label: {
            // サマリー行: 間取り・平均価格・件数
            HStack(spacing: 8) {
                // 間取りラベル
                Text(summary.floorPlan)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(summary.isMatchingLayout ? Color.orange : .primary)
                    .frame(width: 48, alignment: .leading)

                // 同間取りマーク
                if summary.isMatchingLayout {
                    Text("同間取り")
                        .font(.system(size: 8))
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                // 平均成約価格
                VStack(alignment: .trailing, spacing: 1) {
                    Text("平均 \(summary.avgPriceDisplay)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(summary.avgM2PriceManDisplay)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                // 件数
                Text("\(summary.count)件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .tint(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(summary.isMatchingLayout
                      ? Color.orange.opacity(0.06)
                      : Color(.systemGray6).opacity(0.5))
        )
    }

    @ViewBuilder
    private func sameBuildingTransactionRow(
        _ tx: Listing.MarketData.SameBuildingTransaction
    ) -> some View {
        HStack(spacing: 8) {
            // 時期
            Text(tx.periodDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            // 面積
            Text(String(format: "%.0fm²", tx.area))
                .font(.caption2)
                .frame(width: 40, alignment: .leading)

            Spacer()

            // 成約価格
            Text(tx.tradePriceDisplay)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            // m²単価
            Text(tx.m2PriceManDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.orange.opacity(0.03))
        )
    }

    // MARK: - 駅レベル比較

    @ViewBuilder
    private func stationComparisonSection(
        _ station: Listing.MarketData.StationMarketData,
        ward: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // ヘッダー
            HStack(spacing: 6) {
                Image(systemName: "tram.fill")
                    .font(.caption)
                    .foregroundStyle(.indigo)
                Text("「\(station.name)」駅 成約相場")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("直近\(station.sampleCount)件")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // 駅レベル比較カード
            HStack(spacing: 12) {
                // 駅相場
                VStack(alignment: .leading, spacing: 3) {
                    Text("駅圏相場")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(station.medianM2PriceManDisplay)
                        .font(.callout)
                        .fontWeight(.bold)
                        .foregroundStyle(.indigo)
                }

                Divider().frame(height: 30)

                // 乖離率（バックエンド値 or iOS側フォールバック計算）
                VStack(alignment: .leading, spacing: 3) {
                    Text("vs 本物件")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    let ratio = effectiveStationPriceRatio(for: station)
                    Text(effectiveStationPriceRatioDisplay(ratio))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(stationPriceColor(ratio))
                }

                Divider().frame(height: 30)

                // トレンド
                VStack(alignment: .leading, spacing: 3) {
                    Text("トレンド")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: station.trendIconName)
                            .font(.system(size: 10))
                        Text(station.trendDisplay)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(trendColor(station.trend))
                }

                Spacer()

                // YoY
                if station.yoyChangePct != nil {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("前年比")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(station.yoyDisplay)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(yoyColor(station.yoyChangePct))
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.indigo.opacity(0.04))
            )
        }
    }

    // MARK: - m²単価推移チャート

    @ViewBuilder
    private func trendChartSection(_ market: Listing.MarketData) -> some View {
        // 年次データが2つ以上あればそちらを優先
        let wardYearly = market.yearlyM2Prices
        let stationYearly = market.station?.yearlyM2Prices ?? []
        let useYearly = wardYearly.count >= 2 || stationYearly.count >= 2

        VStack(alignment: .leading, spacing: 8) {
            if market.station != nil {
                Text("m²単価推移（\(market.ward) / \(market.station?.name ?? "")駅）")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(market.ward) 中古マンション m²単価推移")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            if useYearly {
                MarketTrendChart(
                    mode: .yearly(
                        wardYearly: wardYearly,
                        stationYearly: stationYearly
                    ),
                    stationName: market.station?.name,
                    listingM2Price: listingM2Price
                )
                .frame(height: 220)
            } else {
                MarketTrendChart(
                    mode: .quarterly(
                        wardQuarterly: market.quarterlyM2Prices,
                        stationQuarterly: market.station?.quarterlyM2Prices ?? []
                    ),
                    stationName: market.station?.name,
                    listingM2Price: listingM2Price
                )
                .frame(height: 220)
            }
        }
    }

    // MARK: - ヘルパー

    /// 物件のm²単価（円）
    private var listingM2Price: Double? {
        guard let priceMan = listing.priceMan, let area = listing.areaM2, area > 0 else { return nil }
        return Double(priceMan) * 10000.0 / area
    }

    private func priceRatioColor(_ ratio: Double?) -> Color {
        guard let ratio else { return .primary }
        let pct = (ratio - 1.0) * 100
        if abs(pct) < 2.0 { return .primary }
        return pct > 0 ? .red : .green
    }

    private func priceDiffColor(_ diff: Int?) -> Color {
        guard let diff else { return .primary }
        if abs(diff) < 50 { return .primary }
        return diff > 0 ? .red : .green
    }

    private func priceRatioBackgroundColor(_ ratio: Double?) -> Color {
        guard let ratio else { return Color(.systemGray6).opacity(0.3) }
        let pct = (ratio - 1.0) * 100
        if abs(pct) < 2.0 { return Color(.systemGray6).opacity(0.3) }
        return pct > 0 ? Color.red.opacity(0.06) : Color.green.opacity(0.06)
    }

    private func trendColor(_ trend: String) -> Color {
        switch trend {
        case "up": return .green
        case "down": return .red
        default: return .primary
        }
    }

    private func yoyColor(_ yoy: Double?) -> Color {
        guard let yoy else { return .primary }
        if abs(yoy) < 0.5 { return .primary }
        return yoy > 0 ? .green : .red
    }

    private func matchTierBadgeColor(_ tier: Int) -> Color {
        switch tier {
        case 1: return Color.green.opacity(0.15)
        case 2: return Color.blue.opacity(0.12)
        case 3: return Color.orange.opacity(0.12)
        default: return Color(.systemGray5)
        }
    }

    /// 駅比較の相場乖離率（バックエンド値がなければ iOS 側で計算）
    private func effectiveStationPriceRatio(
        for station: Listing.MarketData.StationMarketData
    ) -> Double? {
        if let ratio = station.priceRatio { return ratio }
        // フォールバック: 物件m²単価 ÷ 駅圏中央値m²単価
        guard let m2Price = listingM2Price, station.medianM2Price > 0 else { return nil }
        return m2Price / Double(station.medianM2Price)
    }

    /// 乖離率の表示テキスト
    private func effectiveStationPriceRatioDisplay(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        let pct = (ratio - 1.0) * 100
        if abs(pct) < 2.0 { return "相場並み" }
        return pct > 0
            ? String(format: "+%.0f%%（割高）", pct)
            : String(format: "%.0f%%（割安）", pct)
    }

    private func stationPriceColor(_ ratio: Double?) -> Color {
        guard let ratio else { return .primary }
        let pct = (ratio - 1.0) * 100
        if abs(pct) < 2.0 { return .primary }
        return pct > 0 ? .red : .green
    }
}

// MARK: - m²単価推移チャート

struct MarketTrendChart: View {
    /// 表示モード
    enum Mode {
        case yearly(
            wardYearly: [Listing.MarketData.YearlyPrice],
            stationYearly: [Listing.MarketData.YearlyPrice]
        )
        case quarterly(
            wardQuarterly: [Listing.MarketData.QuarterlyPrice],
            stationQuarterly: [Listing.MarketData.QuarterlyPrice]
        )
    }

    let mode: Mode
    var stationName: String?
    let listingM2Price: Double?

    // MARK: - Computed helpers

    /// 凡例表示が必要か（駅データがある場合）
    private var showLegend: Bool {
        switch mode {
        case .yearly(_, let st): return !st.isEmpty
        case .quarterly(_, let st): return !st.isEmpty
        }
    }

    /// 全ラベルをマージ＆ソート
    private var sortedLabels: [String] {
        switch mode {
        case .yearly(let ward, let station):
            let all = Set(ward.map(\.year) + station.map(\.year))
            return all.sorted()
        case .quarterly(let ward, let station):
            let all = Set(ward.map(\.quarter) + station.map(\.quarter))
            return all.sorted()
        }
    }

    /// PointMark サイズ（データが多いほど小さく）
    private var pointSize: CGFloat {
        let n = sortedLabels.count
        if n > 16 { return 8 }
        if n > 10 { return 12 }
        if n > 6 { return 16 }
        return 24
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch mode {
            case .yearly(let wardYearly, let stationYearly):
                yearlyChart(wardYearly: wardYearly, stationYearly: stationYearly)
            case .quarterly(let wardQuarterly, let stationQuarterly):
                quarterlyChart(wardQuarterly: wardQuarterly, stationQuarterly: stationQuarterly)
            }

            // カスタム凡例（駅データがある場合のみ）
            if showLegend {
                legendView
            }
        }
    }

    // MARK: - 年次チャート

    @ViewBuilder
    private func yearlyChart(
        wardYearly: [Listing.MarketData.YearlyPrice],
        stationYearly: [Listing.MarketData.YearlyPrice]
    ) -> some View {
        Chart {
            // 区レベル年次推移
            ForEach(Array(wardYearly.enumerated()), id: \.element.year) { _, yp in
                let manPrice = Double(yp.medianM2Price) / 10000.0
                LineMark(
                    x: .value("年", yp.year),
                    y: .value("m²単価(万)", manPrice),
                    series: .value("系列", "区")
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("年", yp.year),
                    y: .value("m²単価(万)", manPrice)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(pointSize)
            }

            // 駅レベル年次推移
            ForEach(Array(stationYearly.enumerated()), id: \.element.year) { _, yp in
                let manPrice = Double(yp.medianM2Price) / 10000.0
                LineMark(
                    x: .value("年", yp.year),
                    y: .value("m²単価(万)", manPrice),
                    series: .value("系列", "駅")
                )
                .foregroundStyle(Color.indigo)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))

                PointMark(
                    x: .value("年", yp.year),
                    y: .value("m²単価(万)", manPrice)
                )
                .foregroundStyle(Color.indigo)
                .symbolSize(pointSize)
            }

            // 物件の m² 単価ライン
            listingRuleMark
        }
        .chartXScale(domain: sortedLabels)
        .chartYAxis { yAxisMarks }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        // "2021" → "21'"
                        Text(shortYear(label))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    // MARK: - 四半期チャート

    @ViewBuilder
    private func quarterlyChart(
        wardQuarterly: [Listing.MarketData.QuarterlyPrice],
        stationQuarterly: [Listing.MarketData.QuarterlyPrice]
    ) -> some View {
        Chart {
            ForEach(Array(wardQuarterly.enumerated()), id: \.element.quarter) { _, qp in
                let manPrice = Double(qp.medianM2Price) / 10000.0
                LineMark(
                    x: .value("四半期", qp.quarter),
                    y: .value("m²単価(万)", manPrice),
                    series: .value("系列", "区")
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("四半期", qp.quarter),
                    y: .value("m²単価(万)", manPrice)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(pointSize)
            }

            ForEach(Array(stationQuarterly.enumerated()), id: \.element.quarter) { _, qp in
                let manPrice = Double(qp.medianM2Price) / 10000.0
                LineMark(
                    x: .value("四半期", qp.quarter),
                    y: .value("m²単価(万)", manPrice),
                    series: .value("系列", "駅")
                )
                .foregroundStyle(Color.indigo)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))

                PointMark(
                    x: .value("四半期", qp.quarter),
                    y: .value("m²単価(万)", manPrice)
                )
                .foregroundStyle(Color.indigo)
                .symbolSize(pointSize)
            }

            listingRuleMark
        }
        .chartXScale(domain: sortedLabels)
        .chartYAxis { yAxisMarks }
        .chartXAxis {
            AxisMarks { value in
                if let label = value.as(String.self) {
                    if label.hasSuffix("Q1") {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            // "2024Q1" → "24'"
                            Text(shortYear(String(label.prefix(4))))
                                .font(.caption2)
                        }
                    } else {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    // MARK: - 共通パーツ

    @ChartContentBuilder
    private var listingRuleMark: some ChartContent {
        if let listingPrice = listingM2Price {
            let manPrice = listingPrice / 10000.0
            RuleMark(y: .value("物件m²単価", manPrice))
                .foregroundStyle(.red.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("本物件")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
        }
    }

    private var yAxisMarks: some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine()
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    Text(String(format: "%.0f万", v))
                        .font(.caption2)
                }
            }
        }
    }

    private var legendView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 16, height: 2)
                Text("区全体")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.indigo)
                    .frame(width: 16, height: 2)
                Text("\(stationName ?? "駅")駅圏")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red.opacity(0.6))
                    .frame(width: 16, height: 2)
                Text("本物件")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    /// "2024" → "24'"
    private func shortYear(_ year: String) -> String {
        if year.count == 4 {
            return String(year.suffix(2)) + "'"
        }
        return year
    }
}
