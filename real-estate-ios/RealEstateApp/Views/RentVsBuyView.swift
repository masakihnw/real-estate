import SwiftUI

/// 賃貸 vs 購入の比較シミュレーション
struct RentVsBuyView: View {
    let listing: Listing
    @State private var monthlyRent: Double = 250000
    @State private var simulationYears: Double = 10
    @State private var annualRentIncrease: Double = 1.0
    @State private var propertyAppreciation: Double
    @State private var loanRate: Double = 0.5

    init(listing: Listing) {
        self.listing = listing
        self._propertyAppreciation = State(initialValue: listing.ssAppreciationRate ?? 0)
    }

    private var purchasePrice: Double { Double(listing.priceMan ?? 5000) * 10000 }
    private var downPayment: Double { purchasePrice * 0.1 }
    private var loanAmount: Double { purchasePrice * 0.9 }

    private var monthlyLoanPayment: Double {
        let rate = loanRate / 100 / 12
        let months = 35.0 * 12
        if rate == 0 { return loanAmount / months }
        return loanAmount * rate * pow(1 + rate, months) / (pow(1 + rate, months) - 1)
    }

    private var monthlyManagement: Double {
        Double((listing.managementFee ?? 15000) + (listing.repairReserveFund ?? 10000))
    }

    private var monthlyPurchaseCost: Double {
        monthlyLoanPayment + monthlyManagement
    }

    private var totalRentCost: Double {
        var total = 0.0
        var rent = monthlyRent
        for year in 0..<Int(simulationYears) {
            total += rent * 12
            if year > 0 { rent *= (1 + annualRentIncrease / 100) }
        }
        total += monthlyRent * 4
        return total
    }

    private var totalPurchaseCost: Double {
        let loanPayments = monthlyLoanPayment * min(simulationYears, 35) * 12
        let mgmt = monthlyManagement * simulationYears * 12
        let purchaseExpenses = purchasePrice * 0.07
        let propertyTax = purchasePrice * 0.7 * 0.014 * simulationYears
        let sellingCost = purchasePrice * 0.035
        return downPayment + loanPayments + mgmt + purchaseExpenses + propertyTax + sellingCost
    }

    private var propertyValueAtEnd: Double {
        purchasePrice * (1 + propertyAppreciation / 100)
    }

    private var loanBalanceAtEnd: Double {
        let rate = loanRate / 100 / 12
        let totalMonths = 35.0 * 12
        let paidMonths = simulationYears * 12
        if rate == 0 { return loanAmount * (1 - paidMonths / totalMonths) }
        let balance = loanAmount * (pow(1 + rate, totalMonths) - pow(1 + rate, paidMonths)) / (pow(1 + rate, totalMonths) - 1)
        return max(0, balance)
    }

    private var netPurchaseCost: Double {
        totalPurchaseCost - propertyValueAtEnd + loanBalanceAtEnd
    }

    private var isBuyBetter: Bool { netPurchaseCost < totalRentCost }

    var body: some View {
        NavigationStack {
            List {
                Section("賃貸条件") {
                    sliderRow("月額家賃", value: $monthlyRent, range: 100000...500000, step: 10000, format: "¥%.0f")
                    sliderRow("年間賃料上昇率", value: $annualRentIncrease, range: 0...5, step: 0.5, format: "%.1f%%")
                }

                Section("購入条件") {
                    HStack {
                        Text("物件価格")
                        Spacer()
                        Text(Listing.formatPriceCompact(listing.priceMan ?? 0))
                            .foregroundStyle(.secondary)
                    }
                    sliderRow("ローン金利", value: $loanRate, range: 0.1...3.0, step: 0.1, format: "%.1f%%")
                    sliderRow("値上がり率", value: $propertyAppreciation, range: -30...50, step: 1, format: "%.0f%%")
                }

                Section("シミュレーション期間") {
                    sliderRow("居住年数", value: $simulationYears, range: 3...35, step: 1, format: "%.0f年")
                }

                Section("比較結果") {
                    resultRow("賃貸 総コスト", formatMan(totalRentCost), color: .orange)
                    resultRow("購入 総支出", formatMan(totalPurchaseCost), color: .blue)
                    resultRow("売却時 物件価値", formatMan(propertyValueAtEnd), color: .green)
                    resultRow("売却時 ローン残高", formatMan(loanBalanceAtEnd), color: .red)

                    Divider()

                    resultRow("購入 実質コスト", formatMan(netPurchaseCost), color: .blue)
                    resultRow("賃貸 総コスト", formatMan(totalRentCost), color: .orange)

                    HStack {
                        Text(isBuyBetter ? "購入がお得" : "賃貸がお得")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(isBuyBetter ? .green : .orange)
                        Spacer()
                        Text("差額 \(formatMan(abs(totalRentCost - netPurchaseCost)))")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("賃貸 vs 購入")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func resultRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func formatMan(_ value: Double) -> String {
        Listing.formatPriceCompact(Int(value / 10000))
    }
}
