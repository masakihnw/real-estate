import Testing
import Foundation
@testable import RealEstateApp

@Suite("LoanAssumptions 共有前提条件")
struct LoanAssumptionsTests {

    @Test("借入額 = 価格 − 頭金")
    func loanAmount() {
        let a = LoanAssumptions(purchasePriceMan: 9000, interestRatePercent: 1.2, loanYears: 50, downPaymentMan: 1000)
        #expect(a.loanAmountMan == 8000)
        #expect(a.loanAmountYen == 80_000_000)
        #expect(a.purchasePriceYen == 90_000_000)
    }

    @Test("頭金が価格を超えても借入額は0でクランプ")
    func loanAmountFloored() {
        let a = LoanAssumptions(purchasePriceMan: 5000, interestRatePercent: 1.0, loanYears: 35, downPaymentMan: 6000)
        #expect(a.loanAmountMan == 0)
    }

    @Test("月額返済は LoanCalculator と一致")
    func monthlyMatchesCalculator() {
        let a = LoanAssumptions(purchasePriceMan: 9000, interestRatePercent: 1.2, loanYears: 50, downPaymentMan: 0)
        let expected = LoanCalculator.monthlyPayment(principal: 9000, rate: 1.2, years: 50)
        #expect(a.monthlyPaymentMan == expected)
        #expect(a.monthlyPaymentYen == expected * 10_000)
    }

    @Test("返済総額は月額×総月数")
    func totalRepayment() {
        let a = LoanAssumptions(purchasePriceMan: 8000, interestRatePercent: 1.0, loanYears: 35, downPaymentMan: 0)
        let expected = LoanCalculator.totalRepayment(principal: 8000, rate: 1.0, years: 35)
        #expect(a.totalRepaymentMan == expected)
    }

    @Test("from(listing:) は価格を引き継ぎ標準条件（1.2%/50年/頭金0）")
    func fromListingDefaults() {
        let listing = Listing(url: "https://x/1", name: "t", priceMan: 9800, propertyType: "chuko")
        let a = LoanAssumptions.from(listing: listing)
        #expect(a.purchasePriceMan == 9800)
        #expect(a.interestRatePercent == LoanCalculator.annualRate)
        #expect(a.loanYears == LoanCalculator.termYears)
        #expect(a.downPaymentMan == 0)
    }

    @Test("価格 nil の listing は 5000万 フォールバック")
    func fromListingNilPrice() {
        let listing = Listing(url: "https://x/2", name: "t", priceMan: nil, propertyType: "chuko")
        #expect(LoanAssumptions.from(listing: listing).purchasePriceMan == 5000)
    }
}
