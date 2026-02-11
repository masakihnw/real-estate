//
//  SimulationChartView.swift
//  RealEstateApp
//
//  値上がりシミュレーション・含み益シミュレーションの
//  折れ線チャート＋テーブル表示
//
//  計算条件: 返済期間50年 / 金利0.8% / 頭金0円
//

import SwiftUI
import Charts

// MARK: - メインビュー

struct SimulationSectionView: View {
    let listing: Listing

    var body: some View {
        if let sim = LoanCalculator.simulate(listing: listing) {
            VStack(alignment: .leading, spacing: 16) {
                // ── 購入判定 ──
                if let judgment = listing.ssPurchaseJudgment {
                    purchaseJudgmentBadge(judgment)
                }

                // ── 値上がりシミュレーション ──
                appreciationSection(sim)

                Divider()

                // ── 含み益シミュレーション ──
                unrealizedGainSection(sim)

                // 計算条件
                conditionFooter(purchasePrice: sim.purchasePrice)
            }
            .padding(14)
            .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
        }
    }

    // MARK: - 購入判定バッジ

    @ViewBuilder
    private func purchaseJudgmentBadge(_ judgment: String) -> some View {
        HStack {
            Text("購入判定")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(judgment)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(judgment.contains("望ましい") ? Color.green : Color.primary)
        }
    }

    // MARK: - 値上がりシミュレーション

    @ViewBuilder
    private func appreciationSection(_ sim: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("値上がりシミュレーション", systemImage: "chart.line.uptrend.xyaxis")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)

            // テーブル + チャート
            HStack(alignment: .top, spacing: 8) {
                appreciationTable(sim)
                    .frame(maxWidth: .infinity)

                AppreciationChartView(sim: sim)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
    }

    @ViewBuilder
    private func appreciationTable(_ sim: SimulationResult) -> some View {
        VStack(spacing: 0) {
            // ヘッダー
            simTableHeader()

            // ベスト
            simTableRow(
                label: "ベスト",
                color: .blue,
                yr5: sim.bestCase.yr5,
                yr10: sim.bestCase.yr10
            )
            // 標準
            simTableRow(
                label: "標準",
                color: DesignSystem.positiveColor,
                yr5: sim.standardCase.yr5,
                yr10: sim.standardCase.yr10
            )
            // ワースト
            simTableRow(
                label: "ワースト",
                color: DesignSystem.negativeColor,
                yr5: sim.worstCase.yr5,
                yr10: sim.worstCase.yr10
            )
            // ローン残高
            simTableRow(
                label: "ローン残高",
                color: .orange,
                yr5: sim.loanBalance5yr,
                yr10: sim.loanBalance10yr
            )
        }
    }

    // MARK: - 含み益シミュレーション

    @ViewBuilder
    private func unrealizedGainSection(_ sim: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("含み益シミュレーション", systemImage: "yensign.circle")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)

            Text("※(売却額 − 頭金) − ローン残高 = 含み益")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                gainTable(sim)
                    .frame(maxWidth: .infinity)

                GainChartView(sim: sim)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
    }

    @ViewBuilder
    private func gainTable(_ sim: SimulationResult) -> some View {
        VStack(spacing: 0) {
            simTableHeader()

            simTableRow(
                label: "ベスト",
                color: .blue,
                yr5: sim.gainBest.yr5,
                yr10: sim.gainBest.yr10
            )
            simTableRow(
                label: "標準",
                color: DesignSystem.positiveColor,
                yr5: sim.gainStandard.yr5,
                yr10: sim.gainStandard.yr10
            )
            simTableRow(
                label: "ワースト",
                color: DesignSystem.negativeColor,
                yr5: sim.gainWorst.yr5,
                yr10: sim.gainWorst.yr10
            )
        }
    }

    // MARK: - テーブル共通部品

    @ViewBuilder
    private func simTableHeader() -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("5年後")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Text("10年後")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func simTableRow(label: String, color: Color, yr5: Int, yr10: Int) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatMan(yr5))
                .font(.caption)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            Text(formatMan(yr10))
                .font(.caption)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 3)
    }

    // MARK: - フッター

    @ViewBuilder
    private func conditionFooter(purchasePrice: Int) -> some View {
        Text("購入条件 価格: \(formatMan(purchasePrice)) / 金利: 0.8% / 返済期間: 50年 / 頭金: 0万円")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: - ヘルパー

    private func formatMan(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(formatted)万円"
    }
}

// MARK: - 値上がり折れ線チャート

struct AppreciationChartView: View {
    let sim: SimulationResult

    var body: some View {
        let data = chartData()
        Chart(data, id: \.id) { point in
            LineMark(
                x: .value("時期", point.period),
                y: .value("万円", point.value)
            )
            .foregroundStyle(by: .value("ケース", point.caseName))

            PointMark(
                x: .value("時期", point.period),
                y: .value("万円", point.value)
            )
            .foregroundStyle(by: .value("ケース", point.caseName))
            .symbolSize(20)
        }
        .chartForegroundStyleScale([
            "ベスト": Color.blue,
            "標準": DesignSystem.positiveColor,
            "ワースト": DesignSystem.negativeColor,
            "ローン残高": Color.orange,
        ])
        .chartLegend(position: .bottom, spacing: 4)
        .chartLegend(.visible)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text("\(intVal / 10000 > 0 ? "\(intVal)万" : "\(intVal)万")")
                            .font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel()
                    .font(.caption)
            }
        }
        // HIG: VoiceOver でチャートのデータサマリを提供
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("値上がりシミュレーションチャート")
        .accessibilityValue(
            "購入価格\(sim.purchasePrice)万円、5年後 標準\(sim.standardCase.yr5)万円、10年後 標準\(sim.standardCase.yr10)万円"
        )
    }

    private func chartData() -> [ChartPoint] {
        var points: [ChartPoint] = []

        // 購入時
        points.append(.init(caseName: "ベスト", period: "購入時", value: sim.purchasePrice))
        points.append(.init(caseName: "標準", period: "購入時", value: sim.purchasePrice))
        points.append(.init(caseName: "ワースト", period: "購入時", value: sim.purchasePrice))
        points.append(.init(caseName: "ローン残高", period: "購入時", value: sim.purchasePrice))

        // 5年後
        points.append(.init(caseName: "ベスト", period: "5年後", value: sim.bestCase.yr5))
        points.append(.init(caseName: "標準", period: "5年後", value: sim.standardCase.yr5))
        points.append(.init(caseName: "ワースト", period: "5年後", value: sim.worstCase.yr5))
        points.append(.init(caseName: "ローン残高", period: "5年後", value: sim.loanBalance5yr))

        // 10年後
        points.append(.init(caseName: "ベスト", period: "10年後", value: sim.bestCase.yr10))
        points.append(.init(caseName: "標準", period: "10年後", value: sim.standardCase.yr10))
        points.append(.init(caseName: "ワースト", period: "10年後", value: sim.worstCase.yr10))
        points.append(.init(caseName: "ローン残高", period: "10年後", value: sim.loanBalance10yr))

        return points
    }
}

// MARK: - 含み益折れ線チャート

struct GainChartView: View {
    let sim: SimulationResult

    var body: some View {
        let data = chartData()
        Chart(data, id: \.id) { point in
            LineMark(
                x: .value("時期", point.period),
                y: .value("万円", point.value)
            )
            .foregroundStyle(by: .value("ケース", point.caseName))

            PointMark(
                x: .value("時期", point.period),
                y: .value("万円", point.value)
            )
            .foregroundStyle(by: .value("ケース", point.caseName))
            .symbolSize(20)
        }
        .chartForegroundStyleScale([
            "ベスト": Color.blue,
            "標準": DesignSystem.positiveColor,
            "ワースト": DesignSystem.negativeColor,
        ])
        .chartLegend(position: .bottom, spacing: 4)
        .chartLegend(.visible)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text("\(intVal)万")
                            .font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel()
                    .font(.caption)
            }
        }
        // HIG: VoiceOver でチャートのデータサマリを提供
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("含み益シミュレーションチャート")
        .accessibilityValue(
            "5年後 標準\(sim.gainStandard.yr5)万円、10年後 標準\(sim.gainStandard.yr10)万円"
        )
    }

    private func chartData() -> [ChartPoint] {
        var points: [ChartPoint] = []

        // 購入時 (含み益0)
        points.append(.init(caseName: "ベスト", period: "購入時", value: 0))
        points.append(.init(caseName: "標準", period: "購入時", value: 0))
        points.append(.init(caseName: "ワースト", period: "購入時", value: 0))

        // 5年後
        points.append(.init(caseName: "ベスト", period: "5年後", value: sim.gainBest.yr5))
        points.append(.init(caseName: "標準", period: "5年後", value: sim.gainStandard.yr5))
        points.append(.init(caseName: "ワースト", period: "5年後", value: sim.gainWorst.yr5))

        // 10年後
        points.append(.init(caseName: "ベスト", period: "10年後", value: sim.gainBest.yr10))
        points.append(.init(caseName: "標準", period: "10年後", value: sim.gainStandard.yr10))
        points.append(.init(caseName: "ワースト", period: "10年後", value: sim.gainWorst.yr10))

        return points
    }
}

// MARK: - チャートデータ構造

struct ChartPoint: Identifiable {
    let id = UUID()
    let caseName: String
    let period: String
    let value: Int
}
