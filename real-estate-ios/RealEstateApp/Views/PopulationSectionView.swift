//
//  PopulationSectionView.swift
//  RealEstateApp
//
//  e-Stat（総務省統計局）の人口動態データに基づく
//  エリア人口・世帯数・推移チャートセクション。
//

import SwiftUI
import Charts

// MARK: - メインセクション

struct PopulationSectionView: View {
    let listing: Listing

    var body: some View {
        if let pop = listing.parsedPopulationData {
            VStack(alignment: .leading, spacing: 14) {
                // セクションヘッダー
                Label("エリア人口動態", systemImage: "person.3.fill")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)

                // ── 人口・世帯数サマリー ──
                populationSummaryGrid(pop)

                // ── 人口推移チャート ──
                if pop.populationHistory.count >= 2 {
                    Divider()
                    populationTrendChart(pop)
                }

                // ── 高齢化率推移チャート ──
                if pop.hasAgingData {
                    Divider()
                    agingRateChart(pop)
                }

                // フッター
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("出典: \(pop.dataSource)")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
        }
    }

    // MARK: - 人口・世帯数サマリーグリッド

    @ViewBuilder
    private func populationSummaryGrid(_ pop: Listing.PopulationData) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ],
            spacing: 10
        ) {
            summaryCell(
                title: "\(pop.ward)の人口",
                value: pop.populationDisplay,
                icon: "person.2.fill",
                color: .primary
            )
            summaryCell(
                title: "世帯数",
                value: pop.householdsDisplay,
                icon: "house.fill",
                color: .primary
            )
            if pop.hasAgingData {
                summaryCell(
                    title: "高齢化率",
                    value: pop.latestAgingRateDisplay,
                    icon: "figure.senior",
                    color: agingRateColor(pop.latestAgingRate)
                )
            }
            summaryCell(
                title: "前年比",
                value: pop.popChange1yrDisplay,
                icon: "chart.line.uptrend.xyaxis",
                color: changeColor(pop.popChange1yrPct)
            )
            summaryCell(
                title: "5年変動",
                value: pop.popChange5yrDisplay,
                icon: "arrow.up.right",
                color: changeColor(pop.popChange5yrPct)
            )
        }
    }

    @ViewBuilder
    private func summaryCell(
        title: String,
        value: String,
        icon: String,
        color: Color
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.systemGray6).opacity(0.5))
        )
    }

    // MARK: - 人口推移チャート

    @ViewBuilder
    private func populationTrendChart(_ pop: Listing.PopulationData) -> some View {
        let values = pop.populationHistory.map { Double($0.value) / 10000.0 }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 1
        let range = maxVal - minVal
        // データ範囲に対して上下20%のパディングを取り、変化をビビッドに表示
        let padding = max(range * 0.2, 0.05) // 最低0.05万人分の余白
        let yMin = minVal - padding
        let yMax = maxVal + padding
        // 軸の目盛りを3〜4本程度でコンパクトに表示
        let stride = niceStride(for: yMax - yMin, targetTicks: 4)

        VStack(alignment: .leading, spacing: 8) {
            Text("\(pop.ward) 人口推移")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(pop.populationHistory.enumerated()), id: \.element.year) { _, entry in
                    let manPop = Double(entry.value) / 10000.0

                    // 1. AreaMark（背景グラデーション — 最背面に描画）
                    AreaMark(
                        x: .value("年", entry.year),
                        yStart: .value("下限", yMin),
                        yEnd: .value("人口", manPop)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // 2. LineMark（折れ線）
                    LineMark(
                        x: .value("年", entry.year),
                        y: .value("人口", manPop)
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    // 3. PointMark（データ点 — 最前面に描画）
                    PointMark(
                        x: .value("年", entry.year),
                        y: .value("人口", manPop)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(24)
                }
            }
            .chartYScale(domain: yMin ... yMax)
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: stride)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(yAxisLabel(v, stride: stride))
                                .font(.caption2)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 180)
            .clipped()
        }
    }

    /// Y軸ラベルのフォーマット（stride に応じてコンパクトに表示）
    private func yAxisLabel(_ value: Double, stride: Double) -> String {
        if stride >= 1.0 {
            // stride≥1: 整数表示 "69万"
            return String(format: "%.0f万", value)
        } else if stride >= 0.1 {
            // stride≥0.1: 小数1桁 "69.5万"
            return String(format: "%.1f万", value)
        } else {
            // stride<0.1: 小数2桁 "69.75万"
            return String(format: "%.2f万", value)
        }
    }

    /// Y軸の目盛り間隔をキリの良い数値に丸める
    private func niceStride(for range: Double, targetTicks: Int) -> Double {
        guard range > 0, targetTicks > 0 else { return 0.1 }
        let rawStride = range / Double(targetTicks)
        let magnitude = pow(10, floor(log10(rawStride)))
        let normalized = rawStride / magnitude
        let niceNorm: Double
        if normalized <= 1.0 {
            niceNorm = 1.0
        } else if normalized <= 2.0 {
            niceNorm = 2.0
        } else if normalized <= 5.0 {
            niceNorm = 5.0
        } else {
            niceNorm = 10.0
        }
        return niceNorm * magnitude
    }

    // MARK: - 高齢化率チャート

    private static let agingLineNational = "全国平均"
    private static let agingLine23Avg = "23区平均"

    @ViewBuilder
    private func agingRateChart(_ pop: Listing.PopulationData) -> some View {
        let allRates: [Double] = (
            pop.agingRateHistory.map(\.rate) +
            pop.nationalAgingHistory.map(\.rate) +
            pop.tokyo23AvgAgingHistory.map(\.rate)
        )
        let minVal = (allRates.min() ?? 10) - 2
        let maxVal = (allRates.max() ?? 30) + 2
        let stride = niceStride(for: maxVal - minVal, targetTicks: 4)

        VStack(alignment: .leading, spacing: 8) {
            Text("高齢化率の推移（国勢調査）")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(pop.nationalAgingHistory, id: \.year) { entry in
                    LineMark(
                        x: .value("年", entry.year),
                        y: .value("率", entry.rate),
                        series: .value("系列", Self.agingLineNational)
                    )
                    .foregroundStyle(.gray)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("年", entry.year),
                        y: .value("率", entry.rate)
                    )
                    .foregroundStyle(.gray)
                    .symbolSize(16)
                }

                ForEach(pop.tokyo23AvgAgingHistory, id: \.year) { entry in
                    LineMark(
                        x: .value("年", entry.year),
                        y: .value("率", entry.rate),
                        series: .value("系列", Self.agingLine23Avg)
                    )
                    .foregroundStyle(.blue.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("年", entry.year),
                        y: .value("率", entry.rate)
                    )
                    .foregroundStyle(.blue.opacity(0.6))
                    .symbolSize(16)
                }

                ForEach(pop.agingRateHistory, id: \.year) { entry in
                    LineMark(
                        x: .value("年", entry.year),
                        y: .value("率", entry.rate),
                        series: .value("系列", pop.ward)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.monotone)

                    PointMark(
                        x: .value("年", entry.year),
                        y: .value("率", entry.rate)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(28)
                }
            }
            .chartYScale(domain: minVal ... maxVal)
            .chartYAxis {
                AxisMarks(position: .leading, values: .stride(by: stride)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.0f%%", v))
                                .font(.caption2)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let label = value.as(String.self) {
                            Text(label)
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartForegroundStyleScale([
                Self.agingLineNational: Color.gray,
                Self.agingLine23Avg: Color.blue.opacity(0.6),
                pop.ward: Color.accentColor,
            ])
            .chartLegend(position: .bottom, spacing: 4) {
                HStack(spacing: 12) {
                    agingLegendItem(Self.agingLineNational, color: .gray, dashed: true)
                    agingLegendItem(Self.agingLine23Avg, color: .blue.opacity(0.6), dashed: true)
                    agingLegendItem(pop.ward, color: .accentColor, dashed: false)
                }
            }
            .frame(height: 200)
            .clipped()
        }
    }

    @ViewBuilder
    private func agingLegendItem(_ label: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Rectangle()
                    .fill(color)
                    .frame(width: 12, height: 1.5)
                    .overlay(
                        Rectangle()
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            .foregroundStyle(color)
                    )
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: 12, height: 2.5)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - ヘルパー

    private func changeColor(_ pct: Double?) -> Color {
        guard let pct else { return .primary }
        if abs(pct) < 0.3 { return .primary }
        return pct > 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor
    }

    private func agingRateColor(_ rate: Double?) -> Color {
        guard let rate else { return .primary }
        if rate >= 25 { return .orange }
        if rate >= 20 { return .primary }
        return DesignSystem.positiveColor
    }
}
