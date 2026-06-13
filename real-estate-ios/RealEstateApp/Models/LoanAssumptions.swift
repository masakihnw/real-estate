import Foundation

/// お金シミュレーターの共有前提条件（価格・金利・期間・頭金）。
///
/// 6ツール（月額/諸費用/銀行比較/減税/賃貸vs購入/リノベ）がこの1モデルを共有し、
/// 「ツール間で金利を二重入力」問題を解消する（提案 §3.3）。派生値（借入額・月額返済）は
/// 純関数 LoanCalculator を再利用する。
struct LoanAssumptions: Equatable {
    /// 物件価格（万円）
    var purchasePriceMan: Double
    /// ローン金利（年利 %）例: 1.2
    var interestRatePercent: Double
    /// 返済期間（年）
    var loanYears: Int
    /// 頭金（万円）
    var downPaymentMan: Double

    /// 借入額（万円）= 価格 − 頭金（負にならない）
    var loanAmountMan: Double { max(purchasePriceMan - downPaymentMan, 0) }
    var loanAmountYen: Double { loanAmountMan * 10_000 }
    var purchasePriceYen: Double { purchasePriceMan * 10_000 }

    /// 月額返済（万円）
    var monthlyPaymentMan: Double {
        LoanCalculator.monthlyPayment(principal: loanAmountMan, rate: interestRatePercent, years: loanYears)
    }
    /// 月額返済（円）
    var monthlyPaymentYen: Double { monthlyPaymentMan * 10_000 }

    /// 返済総額（万円）
    var totalRepaymentMan: Double {
        LoanCalculator.totalRepayment(principal: loanAmountMan, rate: interestRatePercent, years: loanYears)
    }

    /// listing から既定の前提条件を作る（アプリ標準: 1.2% / 50年 / 頭金0）。
    static func from(listing: Listing) -> LoanAssumptions {
        LoanAssumptions(
            purchasePriceMan: Double(listing.priceMan ?? 5_000),
            interestRatePercent: LoanCalculator.annualRate,
            loanYears: LoanCalculator.termYears,
            downPaymentMan: 0
        )
    }
}
