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
        VStack(alignment: .leading, spacing: 8) {
            Text("\(pop.ward) 人口推移")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(Array(pop.populationHistory.enumerated()), id: \.offset) { _, entry in
                    let manPop = Double(entry.value) / 10000.0
                    LineMark(
                        x: .value("年", entry.year),
                        y: .value("人口(万人)", manPop)
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("年", entry.year),
                        y: .value("人口(万人)", manPop)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    PointMark(
                        x: .value("年", entry.year),
                        y: .value("人口(万人)", manPop)
                    )
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(24)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.1f万", v))
                                .font(.caption2)
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
            .frame(height: 150)
        }
    }

    // MARK: - ヘルパー

    private func changeColor(_ pct: Double?) -> Color {
        guard let pct else { return .primary }
        if abs(pct) < 0.3 { return .primary }
        return pct > 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor
    }
}
