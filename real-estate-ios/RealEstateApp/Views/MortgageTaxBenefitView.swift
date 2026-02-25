import SwiftUI

/// 住宅ローン減税シミュレーション
struct MortgageTaxBenefitView: View {
    let listing: Listing
    @State private var annualIncome: Double = 7000000
    @State private var loanRate: Double = 0.5
    @State private var loanYears: Double = 35

    private var priceYen: Double { Double(listing.priceMan ?? 5000) * 10000 }
    private var loanAmount: Double { priceYen * 0.9 }

    private var isEligible: Bool {
        let area = listing.areaM2 ?? 0
        return area >= 40 && annualIncome <= 20_000_000
    }

    private var deductionRate: Double { 0.007 }

    private var maxDeduction: Int {
        listing.isShinchiku ? 350_000 : 210_000
    }

    private var deductionYears: Int {
        listing.isShinchiku ? 13 : 10
    }

    private var yearlyDeductions: [(year: Int, balance: Int, deduction: Int)] {
        let monthlyRate = loanRate / 100 / 12
        let totalMonths = loanYears * 12
        var result: [(Int, Int, Int)] = []
        for year in 1...deductionYears {
            let paidMonths = Double(year) * 12
            let balance: Double
            if monthlyRate == 0 {
                balance = loanAmount * (1 - paidMonths / totalMonths)
            } else {
                balance = loanAmount * (pow(1 + monthlyRate, totalMonths) - pow(1 + monthlyRate, paidMonths)) / (pow(1 + monthlyRate, totalMonths) - 1)
            }
            let deduction = min(Int(max(0, balance) * deductionRate), maxDeduction)
            result.append((year, Int(max(0, balance)), deduction))
        }
        return result
    }

    private var totalDeduction: Int {
        yearlyDeductions.reduce(0) { $0 + $1.deduction }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("条件") {
                    HStack {
                        Text("物件価格")
                        Spacer()
                        Text(Listing.formatPriceCompact(listing.priceMan ?? 0))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("借入額（90%）")
                        Spacer()
                        Text(Listing.formatPriceCompact(Int(loanAmount / 10000)))
                            .foregroundStyle(.secondary)
                    }
                    sliderRow("年収", value: $annualIncome, range: 3000000...30000000, step: 500000) {
                        formatYenSimple(Int(annualIncome))
                    }
                    sliderRow("ローン金利", value: $loanRate, range: 0.1...3.0, step: 0.1) {
                        String(format: "%.1f%%", loanRate)
                    }
                    HStack {
                        Text("種別")
                        Spacer()
                        Text(listing.isShinchiku ? "新築（控除期間13年）" : "中古（控除期間10年）")
                            .foregroundStyle(.secondary)
                    }
                }

                if !isEligible {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("住宅ローン減税の適用条件を満たしていない可能性があります")
                                .font(.caption)
                        }
                    }
                }

                Section("年別控除額") {
                    ForEach(yearlyDeductions, id: \.year) { item in
                        HStack {
                            Text("\(item.year)年目")
                                .font(.caption)
                                .frame(width: 50, alignment: .leading)
                            Text("残高 \(Listing.formatPriceCompact(item.balance / 10000))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Spacer()
                            Text(formatYenSimple(item.deduction))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("控除合計額")
                            .font(.headline)
                        Spacer()
                        Text(formatYenSimple(totalDeduction))
                            .font(.headline)
                            .foregroundStyle(.green)
                    }
                    Text("※ 実際の控除額は所得税・住民税の納税額が上限となります")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("住宅ローン減税")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(format()).font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func formatYenSimple(_ amount: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return "¥\(f.string(from: NSNumber(value: amount)) ?? "\(amount)")"
    }
}
