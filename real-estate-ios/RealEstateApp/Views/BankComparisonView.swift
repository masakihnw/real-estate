import SwiftUI

/// 複数銀行のローン条件を比較するビュー
struct BankComparisonView: View {
    let listing: Listing
    @State private var loanAmountMan: Double
    @State private var loanYears: Double = 35

    init(listing: Listing) {
        self.listing = listing
        self._loanAmountMan = State(initialValue: Double(listing.priceMan ?? 5000) * 0.9)
    }

    private static let banks: [(name: String, variableRate: Double, fixedRate10: Double, fixedRate35: Double, fee: String)] = [
        ("住信SBIネット銀行", 0.298, 0.86, 1.30, "融資額×2.2%"),
        ("auじぶん銀行", 0.319, 0.915, 1.49, "融資額×2.2%"),
        ("PayPay銀行", 0.315, 0.85, 1.45, "融資額×2.2%"),
        ("楽天銀行", 0.550, 1.10, 1.46, "33万円（固定）"),
        ("みずほ銀行", 0.375, 1.00, 1.54, "33,000円"),
        ("三井住友銀行", 0.475, 1.05, 1.59, "33,000円"),
        ("三菱UFJ銀行", 0.345, 0.92, 1.55, "33,000円"),
        ("りそな銀行", 0.340, 0.93, 1.56, "33,000円 + 融資額×2.2%"),
    ]

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
                        Slider(value: $loanYears, in: 10...35, step: 1)
                    }
                }

                Section("変動金利") {
                    ForEach(Self.banks, id: \.name) { bank in
                        bankRow(bank: bank.name, rate: bank.variableRate, fee: bank.fee)
                    }
                }

                Section("固定10年") {
                    ForEach(Self.banks, id: \.name) { bank in
                        bankRow(bank: bank.name, rate: bank.fixedRate10, fee: bank.fee)
                    }
                }

                Section("全期間固定") {
                    ForEach(Self.banks, id: \.name) { bank in
                        bankRow(bank: bank.name, rate: bank.fixedRate35, fee: bank.fee)
                    }
                }
            }
            .navigationTitle("銀行ローン比較")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func bankRow(bank: String, rate: Double, fee: String) -> some View {
        let monthly = calculateMonthlyPayment(
            principal: loanAmountMan * 10000,
            annualRate: rate / 100,
            years: Int(loanYears)
        )
        let total = monthly * Double(Int(loanYears) * 12)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bank)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.3f%%", rate))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.blue)
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
