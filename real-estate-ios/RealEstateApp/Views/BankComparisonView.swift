import SwiftUI

/// 複数銀行のローン条件を比較するビュー
struct BankComparisonView: View {
    private struct BankRate {
        let name: String
        let variableRate: Double
        let fixedRate10: Double
        let fixedRate35: Double
        let fee: String
    }

    let listing: Listing
    @State private var loanAmountMan: Double
    @State private var loanYears: Double = 35

    private static let fullDanshinPremiumRate: Double = 0.4
    private static let extraLongTermPremiumRate: Double = 0.1

    init(listing: Listing) {
        self.listing = listing
        self._loanAmountMan = State(initialValue: Double(listing.priceMan ?? 5000) * 0.9)
    }

    // 2026-04-02 時点で公式サイトを確認しつつ、キャンペーン/審査差をならした比較用の概算値。
    // 実際は借入比率・審査結果・キャンペーンで上下するため、詳細は各行の見積り確認が必要。
    private static let banks: [BankRate] = [
        .init(name: "住信SBIネット銀行", variableRate: 0.78, fixedRate10: 1.88, fixedRate35: 2.35, fee: "融資額×2.2%"),
        .init(name: "auじぶん銀行", variableRate: 1.05, fixedRate10: 3.64, fixedRate35: 2.60, fee: "融資額×2.2%"),
        .init(name: "PayPay銀行", variableRate: 1.15, fixedRate10: 2.65, fixedRate35: 2.85, fee: "融資額×2.2%"),
        .init(name: "楽天銀行", variableRate: 2.65, fixedRate10: 2.10, fixedRate35: 2.45, fee: "33万円（固定）"),
        .init(name: "みずほ銀行", variableRate: 1.03, fixedRate10: 2.15, fixedRate35: 2.55, fee: "33,000円"),
        .init(name: "三井住友銀行", variableRate: 0.93, fixedRate10: 3.05, fixedRate35: 4.70, fee: "33,000円"),
        .init(name: "三菱UFJ銀行", variableRate: 0.95, fixedRate10: 2.92, fixedRate35: 3.60, fee: "33,000円"),
        .init(name: "りそな銀行", variableRate: 0.64, fixedRate10: 3.26, fixedRate35: 4.08, fee: "33,000円 + 融資額×2.2%"),
    ]

    private var isLongerThan35Years: Bool {
        Int(loanYears) > 35
    }

    var body: some View {
        NavigationStack {
            List {
                Section("ローン条件") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("借入額")
                            Spacer()
                            Text(Listing.formatPriceCompact(Int(loanAmountMan)))
                        }
                        Slider(value: $loanAmountMan, in: 1000...20000, step: 100)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("返済期間")
                            Spacer()
                            Text("\(Int(loanYears))年")
                        }
                        Slider(value: $loanYears, in: 10...50, step: 1)
                    }
                }

                Section("注意") {
                    Text("金利は 2026年4月初旬に各行公式サイトを見ながら比較用の概算に更新しています。団信フルは基本金利に +0.4% を上乗せした目安です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isLongerThan35Years {
                        Text("35年超の借入は銀行によって +0.1% 上乗せになることがあります。特に PayPay 銀行は公式に注意書きがあります。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("変動金利") {
                    ForEach(Self.banks, id: \.name) { bank in
                        bankRow(bank: bank, rate: bank.variableRate, fee: bank.fee)
                    }
                }

                Section("固定10年") {
                    ForEach(Self.banks, id: \.name) { bank in
                        bankRow(bank: bank, rate: bank.fixedRate10, fee: bank.fee)
                    }
                }

                Section("全期間固定") {
                    ForEach(Self.banks, id: \.name) { bank in
                        bankRow(bank: bank, rate: bank.fixedRate35, fee: bank.fee)
                    }
                }
            }
            .navigationTitle("銀行ローン比較")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func bankRow(bank: BankRate, rate: Double, fee: String) -> some View {
        let adjustedRate = effectiveRate(from: rate)
        let fullDanshinRate = adjustedRate + Self.fullDanshinPremiumRate
        let monthly = calculateMonthlyPayment(
            principal: loanAmountMan * 10000,
            annualRate: adjustedRate / 100,
            years: Int(loanYears)
        )
        let monthlyWithFullDanshin = calculateMonthlyPayment(
            principal: loanAmountMan * 10000,
            annualRate: fullDanshinRate / 100,
            years: Int(loanYears)
        )
        let total = monthly * Double(Int(loanYears) * 12)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bank.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f%%", adjustedRate))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.blue)
            }
            HStack {
                Text("団信フル目安")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f%%", fullDanshinRate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("月額返済")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatYen(Int(monthly)))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            HStack {
                Text("月額返済（団信フル）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatYen(Int(monthlyWithFullDanshin)))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("総返済額")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Listing.formatPriceCompact(Int(total / 10000)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("手数料")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(fee)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func effectiveRate(from baseRate: Double) -> Double {
        baseRate + (isLongerThan35Years ? Self.extraLongTermPremiumRate : 0)
    }

    private func calculateMonthlyPayment(principal: Double, annualRate: Double, years: Int) -> Double {
        let monthlyRate = annualRate / 12
        let months = Double(years * 12)
        if monthlyRate == 0 { return principal / months }
        let numerator = principal * monthlyRate * pow(1 + monthlyRate, months)
        let denominator = pow(1 + monthlyRate, months) - 1
        return numerator / denominator
    }

    private func formatYen(_ amount: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return "¥\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)")"
    }
}
