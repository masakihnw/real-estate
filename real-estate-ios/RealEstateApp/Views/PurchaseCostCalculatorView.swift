import SwiftUI

/// 購入諸費用シミュレーション。共有前提条件（価格・頭金から導く借入額）に対して諸費用を計算。
/// MoneySimulatorView の単一 List 内に Section として埋め込まれる（NavigationStack/List は持たない）。
struct PurchaseCostCalculatorView: View {
    let listing: Listing
    let assumptions: LoanAssumptions

    private var priceYen: Double { assumptions.purchasePriceYen }
    private var loanAmount: Double { assumptions.loanAmountYen }

    private var stampTax: Int {
        switch priceYen {
        case ..<10_000_000: return 10_000
        case ..<50_000_000: return 20_000
        case ..<100_000_000: return 60_000
        default: return 100_000
        }
    }

    private var registrationTax: Int {
        let fixedAssetValue = priceYen * 0.7
        let ownershipRate = 0.02
        let mortgageRate = 0.001
        return Int(fixedAssetValue * ownershipRate + loanAmount * mortgageRate)
    }

    private var agencyFee: Int {
        return Int(priceYen * 0.03 + 66_000) + Int((priceYen * 0.03 + 66_000) * 0.1)
    }

    private var loanExpenses: Int {
        let guarantee = Int(loanAmount * 0.02)
        let processingFee = 33_000
        let mortgageStampTax: Int
        switch loanAmount {
        case ..<10_000_000: mortgageStampTax = 10_000
        case ..<50_000_000: mortgageStampTax = 20_000
        default: mortgageStampTax = 60_000
        }
        return guarantee + processingFee + mortgageStampTax
    }

    private var fireInsurance: Int { 150_000 }

    private var judicialScrivenerFee: Int { 150_000 }

    private var fixedPropertyTaxSettlement: Int {
        Int(priceYen * 0.7 * 0.014 * 0.5)
    }

    private var managementFundSettlement: Int {
        let monthly = (listing.managementFee ?? 15_000) + (listing.repairReserveFund ?? 10_000)
        return monthly
    }

    private var acquisitionTax: Int {
        let fixedAssetLand = priceYen * 0.3 * 0.7
        let fixedAssetBuilding = priceYen * 0.7 * 0.7
        let landTax = fixedAssetLand * 0.015
        var buildingTax = fixedAssetBuilding * 0.03
        return Int(landTax + buildingTax)
    }

    private var totalCost: Int {
        stampTax + registrationTax + agencyFee + loanExpenses + fireInsurance +
        judicialScrivenerFee + fixedPropertyTaxSettlement + acquisitionTax
    }

    private var totalCostRatio: Double {
        guard priceYen > 0 else { return 0 }
        return Double(totalCost) / priceYen * 100
    }

    var body: some View {
        Group {
            Section("諸費用内訳") {
                costRow("印紙税", stampTax)
                costRow("登録免許税", registrationTax)
                costRow("仲介手数料（税込）", agencyFee)
                costRow("ローン関連費用", loanExpenses)
                costRow("火災保険料", fireInsurance)
                costRow("司法書士報酬", judicialScrivenerFee)
                costRow("固定資産税精算金", fixedPropertyTaxSettlement)
                costRow("不動産取得税", acquisitionTax)
            }

            Section {
                HStack {
                    Text("諸費用合計")
                        .font(.headline)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(formatYen(totalCost))
                            .font(.headline)
                            .foregroundStyle(.blue)
                        Text(String(format: "物件価格の %.1f%%", totalCostRatio))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("購入総額")
                        .font(.headline)
                    Spacer()
                    Text(Listing.formatPriceCompact(Int(assumptions.purchasePriceMan) + totalCost / 10000))
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            }

            Section("月額管理費・修繕積立金") {
                costRow("管理費", listing.managementFee ?? 0)
                costRow("修繕積立金", listing.repairReserveFund ?? 0)
                HStack {
                    Text("月額合計")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(formatYen(managementFundSettlement))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func costRow(_ label: String, _ amount: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(formatYen(amount))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func formatYen(_ amount: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let formatted = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return "¥\(formatted)"
    }
}
