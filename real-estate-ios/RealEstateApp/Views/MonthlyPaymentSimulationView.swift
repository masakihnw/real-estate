//
//  MonthlyPaymentSimulationView.swift
//  RealEstateApp
//
//  月額支払いシミュレーション — 諸費用6.5%込み・内訳バー・プリセット付き
//
//  計算式: 元利均等返済 M = P * r * (1+r)^n / ((1+r)^n - 1)
//  借入額 = (物件価格 - 頭金) × 1.065（購入諸費用6.5%）
//

import SwiftUI

struct MonthlyPaymentSimulationView: View {
    let listing: Listing

    // MARK: - フォーム状態

    @State private var isExpanded: Bool = false
    private static let defaultInterestRate: Double = 1.2

    @State private var interestRate: Double = Self.defaultInterestRate
    @State private var loanYears: Int = LoanCalculator.termYears
    @State private var downPaymentMan: Double = 0

    private static let yearOptions: [Int] = [20, 30, 35, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50]

    // MARK: - 計算値

    private var principalMan: Double {
        let price = Double(listing.priceMan ?? 0)
        return max(price - downPaymentMan, 0) * DesignSystem.purchaseFeeMultiplier
    }

    private var loanMonthlyMan: Double {
        LoanCalculator.monthlyPayment(principal: principalMan, rate: interestRate, years: loanYears)
    }

    private var loanMonthlyYen: Int {
        Int(round(loanMonthlyMan * 10000))
    }

    private var mgmtFee: Int { listing.managementFee ?? 0 }
    private var repairFund: Int { listing.repairReserveFund ?? 0 }

    private var totalMonthlyYen: Int {
        loanMonthlyYen + mgmtFee + repairFund
    }

    private var totalMonthlyMan: Double {
        loanMonthlyMan + Double(mgmtFee) / 10000.0 + Double(repairFund) / 10000.0
    }

    private var totalRepaymentMan: Double {
        LoanCalculator.totalRepayment(principal: principalMan, rate: interestRate, years: loanYears)
    }

    private var hasFixedCost: Bool { mgmtFee > 0 || repairFund > 0 }

    private var maxDownPayment: Double {
        Double(listing.priceMan ?? 0)
    }

    private var isCustom: Bool {
        interestRate != Self.defaultInterestRate
            || loanYears != LoanCalculator.termYears
            || downPaymentMan != 0
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 合計額ヘッダー
            totalHeader

            // 借入額注記
            Text("借入額 \(formatManYen(principalMan))（諸費用6.5%込）")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // 内訳テキスト
            HStack(spacing: 0) {
                Text("ローン\(String(format: "%.1f", loanMonthlyMan))")
                Text(" + 管理費\(String(format: "%.1f", Double(mgmtFee) / 10000.0))")
                Text(" + 修繕\(String(format: "%.1f", Double(repairFund) / 10000.0))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // 内訳バー
            breakdownBar

            // トグルボタン
            simToggleButton

            if isExpanded {
                // 内訳詳細
                breakdownDetail
                // フォーム
                formSection
                // プリセット
                presetButtons
            }
        }
        .padding(12)
        .listingGlassBackground()
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    // MARK: - 合計ヘッダー

    private var totalHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label("月額支払いシミュレーション", systemImage: "yensign.circle")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("約\(String(format: "%.1f", totalMonthlyMan))")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Text("万円/月")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - 内訳バー

    private var breakdownBar: some View {
        GeometryReader { geo in
            let total = max(totalMonthlyMan, 0.01)
            let loanW = (loanMonthlyMan / total) * geo.size.width
            let mgmtW = (Double(mgmtFee) / 10000.0 / total) * geo.size.width
            let repairW = (Double(repairFund) / 10000.0 / total) * geo.size.width

            HStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: max(loanW, 2))
                if mgmtFee > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DesignSystem.positiveColor)
                        .frame(width: max(mgmtW, 2))
                }
                if repairFund > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.orange)
                        .frame(width: max(repairW, 2))
                }
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - トグルボタン

    private var simToggleButton: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("条件を変更してシミュレーション")
                    .font(.caption)
                Spacer()
                Text("\(String(format: "%.1f", interestRate))% / \(loanYears)年 / 頭金\(Int(downPaymentMan))万")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内訳詳細

    private var breakdownDetail: some View {
        VStack(spacing: 4) {
            breakdownRow(title: "ローン返済", yen: loanMonthlyYen, color: .accentColor)
            if mgmtFee > 0 {
                breakdownRow(title: "管理費", yen: mgmtFee, color: DesignSystem.positiveColor)
            }
            if repairFund > 0 {
                breakdownRow(title: "修繕積立金", yen: repairFund, color: .orange)
            }
            if !hasFixedCost {
                Text("※ 管理費・修繕積立金は未取得（ローン返済額のみ）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("返済総額（参考）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatManYen(totalRepaymentMan))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - フォーム

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("金利（年利）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("\(interestRate, specifier: "%.2f")%")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                    Spacer()
                    Stepper("", value: $interestRate, in: 0.1...5.0, step: 0.01)
                        .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("返済期間")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Menu {
                    Picker("返済期間", selection: $loanYears) {
                        ForEach(Self.yearOptions, id: \.self) { year in
                            Text("\(year)年").tag(year)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("\(loanYears)年")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if maxDownPayment > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("頭金")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("\(Int(downPaymentMan))万円")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .frame(width: 80, alignment: .leading)
                        Slider(
                            value: $downPaymentMan,
                            in: 0...maxDownPayment,
                            step: max(maxDownPayment / 100, 10)
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - プリセットボタン

    private var presetButtons: some View {
        let price = listing.priceMan ?? 0
        let presets: [(String, Double, Int, Double)] = [
            ("基準", 1.2, 50, 0),
            ("頭金1割", 1.2, 50, Double(Int(Double(price) * 0.1 / 100) * 100)),
            ("頭金2割", 1.2, 50, Double(Int(Double(price) * 0.2 / 100) * 100)),
            ("35年返済", 1.2, 35, 0),
        ]

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.0) { preset in
                    let rateMatch = interestRate == preset.1
                    let yearsMatch = loanYears == preset.2
                    let downMatch = downPaymentMan == preset.3
                    let isOn = rateMatch && yearsMatch && downMatch
                    let bg: Color = isOn ? Color.accentColor.opacity(0.15) : Color(.systemGray6)
                    let fg: Color = isOn ? Color.accentColor : Color.primary
                    Button {
                        withAnimation {
                            interestRate = preset.1
                            loanYears = preset.2
                            downPaymentMan = preset.3
                        }
                    } label: {
                        Text(preset.0)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(bg)
                            .foregroundStyle(fg)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - ヘルパー

    private func breakdownRow(title: String, yen: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(yen.formatted())円")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func formatManYen(_ man: Double) -> String {
        let intMan = Int(round(man))
        if intMan >= 10000 {
            let oku = intMan / 10000
            let remainder = intMan % 10000
            if remainder == 0 {
                return "\(oku)億円"
            }
            return "\(oku)億\(remainder)万円"
        }
        return "\(intMan.formatted())万円"
    }
}
