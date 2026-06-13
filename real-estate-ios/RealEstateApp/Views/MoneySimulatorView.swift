import SwiftUI

/// お金の統合シミュレーター（提案 §3.3）。
///
/// 上部に共有前提条件（価格・金利・期間・頭金）パネル、下部にセグメントで5ツールの
/// 結果ビューを切り替える。各ツールは `Group { Section… }` を返し、この単一 List に
/// 合流する（各ツールは NavigationStack/List を持たない）。
/// 「ツール間で金利を二重入力」と「アイコン6連発ボタン」を解消する。
struct MoneySimulatorView: View {
    let listing: Listing
    @State private var assumptions: LoanAssumptions
    @State private var selectedTool: MoneyTool = .purchaseCost
    @Environment(\.dismiss) private var dismiss

    init(listing: Listing) {
        self.listing = listing
        self._assumptions = State(initialValue: .from(listing: listing))
    }

    enum MoneyTool: String, CaseIterable, Identifiable {
        case purchaseCost = "諸費用"
        case bank = "銀行比較"
        case tax = "減税"
        case rentVsBuy = "賃貸/購入"
        case renovation = "リノベ"

        var id: String { rawValue }
        /// 前提条件パネルを使うか（リノベは面積のみで価格/金利/期間/頭金を使わない）
        var usesAssumptions: Bool { self != .renovation }
        /// 共有金利を使うか（銀行比較は各行の金利表が主役なので使わない）
        var usesInterestRate: Bool { self != .bank }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("ツール", selection: $selectedTool) {
                        ForEach(MoneyTool.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if selectedTool.usesAssumptions {
                    assumptionsSection
                }

                selectedToolBody
            }
            .navigationTitle("お金のシミュレーター")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedToolBody: some View {
        switch selectedTool {
        case .purchaseCost:
            PurchaseCostCalculatorView(listing: listing, assumptions: assumptions)
        case .bank:
            BankComparisonView(listing: listing, assumptions: assumptions)
        case .tax:
            MortgageTaxBenefitView(listing: listing, assumptions: assumptions)
        case .rentVsBuy:
            RentVsBuyView(listing: listing, assumptions: assumptions)
        case .renovation:
            RenovationEstimateView(listing: listing)
        }
    }

    private var assumptionsSection: some View {
        Section("前提条件") {
            assumptionSlider(
                "物件価格", value: $assumptions.purchasePriceMan, range: 1000...30000, step: 100,
                display: Listing.formatPriceCompact(Int(assumptions.purchasePriceMan))
            )
            if selectedTool.usesInterestRate {
                assumptionSlider(
                    "金利", value: $assumptions.interestRatePercent, range: 0.1...3.0, step: 0.05,
                    display: String(format: "%.2f%%", assumptions.interestRatePercent)
                )
            }
            assumptionSlider(
                "返済期間", value: loanYearsBinding, range: 10...50, step: 1,
                display: "\(assumptions.loanYears)年"
            )
            assumptionSlider(
                "頭金", value: $assumptions.downPaymentMan, range: 0...assumptions.purchasePriceMan, step: 100,
                display: Listing.formatPriceCompact(Int(assumptions.downPaymentMan))
            )
            HStack {
                Text("借入額")
                Spacer()
                Text(Listing.formatPriceCompact(Int(assumptions.loanAmountMan)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// loanYears(Int) を Slider(Double) で編集するためのブリッジ
    private var loanYearsBinding: Binding<Double> {
        Binding(
            get: { Double(assumptions.loanYears) },
            set: { assumptions.loanYears = Int($0.rounded()) }
        )
    }

    private func assumptionSlider(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(display).font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
