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

                // ── 相場乖離率カード ──
                priceComparisonCard(market)

                // ── エリア相場情報 ──
                areaInfoGrid(market)

                // ── 四半期推移チャート ──
                if market.quarterlyM2Prices.count >= 3 {
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
                    Text("掲載価格 vs 成約相場")
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

            // 補足: サンプル数
            HStack {
                Text("\(market.ward)の直近成約\(market.sampleCount)件から算出")
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
                title: "成約相場",
                value: market.wardMedianM2PriceManDisplay,
                icon: "yensign.circle"
            )
            areaInfoCell(
                title: "エリアトレンド",
                value: market.trendDisplay,
                icon: market.trendIconName,
                color: trendColor(market.trend)
            )
            areaInfoCell(
                title: "前年比",
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
        color: Color = .primary
    ) -> some View {
        VStack(spacing: 4) {
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.systemGray6).opacity(0.5))
        )
    }

    // MARK: - 四半期推移チャート

    @ViewBuilder
    private func trendChartSection(_ market: Listing.MarketData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(market.ward) 中古マンション m²単価推移")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            MarketTrendChart(
                quarterlyPrices: market.quarterlyM2Prices,
                listingM2Price: listingM2Price
            )
            .frame(height: 180)
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
}

// MARK: - 四半期推移チャート

struct MarketTrendChart: View {
    let quarterlyPrices: [Listing.MarketData.QuarterlyPrice]
    let listingM2Price: Double?

    var body: some View {
        Chart {
            // エリア成約相場の推移
            ForEach(Array(quarterlyPrices.enumerated()), id: \.offset) { _, qp in
                let manPrice = Double(qp.medianM2Price) / 10000.0
                LineMark(
                    x: .value("四半期", qp.quarter),
                    y: .value("m²単価(万)", manPrice)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("四半期", qp.quarter),
                    y: .value("m²単価(万)", manPrice)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(20)
            }

            // 物件のm²単価ライン
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
        .chartYAxis {
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
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        // "2024Q3" → "24Q3" に短縮
                        let short = label.count > 4 ? String(label.suffix(label.count - 2)) : label
                        Text(short)
                            .font(.caption2)
                            .rotationEffect(.degrees(-30))
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }
}
