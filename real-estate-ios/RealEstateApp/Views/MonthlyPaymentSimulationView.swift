//
//  MonthlyPaymentSimulationView.swift
//  RealEstateApp
//
//  月額支払いシミュレーション — 動的フォーム付き
//
//  タップで展開し、金利・返済期間・頭金を変更してリアルタイムに再計算する。
//  計算式: 元利均等返済 M = P * r * (1+r)^n / ((1+r)^n - 1)
//

import SwiftUI

struct MonthlyPaymentSimulationView: View {
    let listing: Listing

    // MARK: - フォーム状態

    @State private var isExpanded: Bool = false
    @State private var interestRate: Double = LoanCalculator.annualRate   // デフォルト 0.8%
    @State private var loanYears: Int = LoanCalculator.termYears          // デフォルト 50年
    @State private var downPaymentMan: Double = 0                         // 頭金（万円）

    // MARK: - 返済期間の選択肢
    private static let yearOptions: [Int] = Array(stride(from: 5, through: 50, by: 5))

    // MARK: - 計算値

    /// 借入元本（万円）
    private var principalMan: Double {
        let price = Double(listing.priceMan ?? 0)
        return max(price - downPaymentMan, 0)
    }

    /// ローン月額返済額（円）
    private var loanMonthlyYen: Int {
        let man = LoanCalculator.monthlyPayment(principal: principalMan, rate: interestRate, years: loanYears)
        return Int(round(man * 10000))
    }

    /// 管理費（円/月）
    private var mgmtFee: Int { listing.managementFee ?? 0 }

    /// 修繕積立金（円/月）
    private var repairFund: Int { listing.repairReserveFund ?? 0 }

    /// 月額合計（円）
    private var totalMonthlyYen: Int {
        loanMonthlyYen + mgmtFee + repairFund
    }

    /// 返済総額（万円）
    private var totalRepaymentMan: Double {
        LoanCalculator.totalRepayment(principal: principalMan, rate: interestRate, years: loanYears)
    }

    private var hasFixedCost: Bool { mgmtFee > 0 || repairFund > 0 }

    /// 頭金の上限（万円）
    private var maxDownPayment: Double {
        Double(listing.priceMan ?? 0)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ヘッダー + 折りたたみ合計表示
            headerView

            if isExpanded {
                Divider()
                formSection
                Divider()
            }

            // 計算結果
            resultSection

            // 注記
            conditionNote
        }
        .padding(12)
        .listingGlassBackground()
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    // MARK: - ヘッダー

    private var headerView: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack {
                Label("月額支払いシミュレーション", systemImage: "yensign.circle")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - フォーム

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 金利
            VStack(alignment: .leading, spacing: 4) {
                Text("金利（年利）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("\(interestRate, specifier: "%.2f")%")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .frame(width: 56, alignment: .trailing)
                    Stepper("", value: $interestRate, in: 0.1...5.0, step: 0.01)
                        .labelsHidden()
                }
            }

            // 返済期間
            VStack(alignment: .leading, spacing: 4) {
                Text("返済期間")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("返済期間", selection: $loanYears) {
                    ForEach(Self.yearOptions, id: \.self) { year in
                        Text("\(year)年").tag(year)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 頭金
            if maxDownPayment > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("頭金")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("\(Int(downPaymentMan))万円")
                            .font(.system(.subheadline, design: .rounded).weight(.medium))
                            .frame(width: 80, alignment: .trailing)
                        Slider(
                            value: $downPaymentMan,
                            in: 0...maxDownPayment,
                            step: max(maxDownPayment / 100, 10)
                        )
                    }
                }
            }

            // リセットボタン
            if interestRate != LoanCalculator.annualRate
                || loanYears != LoanCalculator.termYears
                || downPaymentMan != 0 {
                Button {
                    withAnimation {
                        interestRate = LoanCalculator.annualRate
                        loanYears = LoanCalculator.termYears
                        downPaymentMan = 0
                    }
                } label: {
                    Label("デフォルトに戻す", systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 計算結果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 合計月額
            HStack(alignment: .firstTextBaseline) {
                Text("月額合計（目安）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(totalMonthlyYen.formatted())円")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Text("/月")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 内訳
            breakdownRow(title: "ローン返済", yen: loanMonthlyYen)
            if hasFixedCost {
                if mgmtFee > 0 {
                    breakdownRow(title: "管理費", yen: mgmtFee)
                }
                if repairFund > 0 {
                    breakdownRow(title: "修繕積立金", yen: repairFund)
                }
            } else {
                Text("※ 管理費・修繕積立金は未取得（ローン返済額のみ）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // 返済総額（展開時のみ表示）
            if isExpanded {
                Divider()
                    .padding(.vertical, 2)
                HStack {
                    Text("返済総額（参考）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatManYen(totalRepaymentMan))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if downPaymentMan > 0 {
                    HStack {
                        Text("借入額")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(Int(principalMan).formatted())万円")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - 注記

    private var conditionNote: some View {
        Group {
            if isExpanded {
                Text("※ 元利均等返済で計算。変動金利の将来変動は考慮していません")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("※ 金利\(String(format: "%.1f", interestRate))%・返済\(loanYears)年・頭金\(Int(downPaymentMan))万円で計算")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - ヘルパー

    private func breakdownRow(title: String, yen: Int) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(yen.formatted())円")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 万円表示（1億以上は「X億Y万円」形式）
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
