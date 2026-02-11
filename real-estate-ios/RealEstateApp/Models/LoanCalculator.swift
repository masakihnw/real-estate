//
//  LoanCalculator.swift
//  RealEstateApp
//
//  ローン残高・含み益シミュレーション計算
//  条件: 返済期間50年、金利0.8%（固定）、頭金0円、元利均等返済
//

import Foundation

/// ローンシミュレーションの計算ユーティリティ
enum LoanCalculator {
    // MARK: - 定数（ユーザー指定の計算条件）

    /// 返済期間（年）
    static let termYears: Int = 50
    /// 年利 (%)
    static let annualRate: Double = 0.8
    /// 頭金（万円）
    static let downPayment: Int = 0

    // MARK: - 元利均等返済の月額返済額

    /// 月額返済額を計算（万円単位）
    static func monthlyPayment(principal: Double) -> Double {
        let monthlyRate = annualRate / 100.0 / 12.0
        let totalMonths = Double(termYears * 12)

        if monthlyRate == 0 {
            return principal / totalMonths
        }

        // 元利均等返済: M = P * r * (1+r)^n / ((1+r)^n - 1)
        let factor = pow(1 + monthlyRate, totalMonths)
        return principal * monthlyRate * factor / (factor - 1)
    }

    // MARK: - N年後のローン残高

    /// n年後のローン残高を計算（万円単位）
    static func loanBalance(principal: Double, afterYears: Int) -> Double {
        let monthlyRate = annualRate / 100.0 / 12.0
        let totalMonths = Double(termYears * 12)
        let elapsedMonths = Double(afterYears * 12)

        if monthlyRate == 0 {
            return principal * (1 - elapsedMonths / totalMonths)
        }

        let payment = monthlyPayment(principal: principal)

        // 残高 = P * (1+r)^k - M * ((1+r)^k - 1) / r
        let factor = pow(1 + monthlyRate, elapsedMonths)
        let balance = principal * factor - payment * (factor - 1) / monthlyRate
        return max(balance, 0)
    }

    // MARK: - シミュレーション結果

    /// 値上がりシミュレーション + 含み益の一括計算
    static func simulate(listing: Listing) -> SimulationResult? {
        guard listing.hasSimulationData else { return nil }
        guard let purchasePrice = listing.priceMan ?? listing.ssOkiPrice70m2 else { return nil }

        let principal = Double(purchasePrice - downPayment)

        let balance5yr = loanBalance(principal: principal, afterYears: 5)
        let balance10yr = loanBalance(principal: principal, afterYears: 10)

        let best5 = listing.ssSimBest5yr ?? 0
        let best10 = listing.ssSimBest10yr ?? 0
        let std5 = listing.ssSimStandard5yr ?? 0
        let std10 = listing.ssSimStandard10yr ?? 0
        let worst5 = listing.ssSimWorst5yr ?? 0
        let worst10 = listing.ssSimWorst10yr ?? 0

        return SimulationResult(
            purchasePrice: purchasePrice,
            // 値上がり
            bestCase: .init(yr5: best5, yr10: best10),
            standardCase: .init(yr5: std5, yr10: std10),
            worstCase: .init(yr5: worst5, yr10: worst10),
            // ローン残高
            loanBalance5yr: Int(round(balance5yr)),
            loanBalance10yr: Int(round(balance10yr)),
            // 含み益 = 売却額 - ローン残高 （頭金0のため）
            gainBest: .init(yr5: best5 - Int(round(balance5yr)), yr10: best10 - Int(round(balance10yr))),
            gainStandard: .init(yr5: std5 - Int(round(balance5yr)), yr10: std10 - Int(round(balance10yr))),
            gainWorst: .init(yr5: worst5 - Int(round(balance5yr)), yr10: worst10 - Int(round(balance10yr)))
        )
    }
}

// MARK: - データ構造

struct SimulationResult {
    let purchasePrice: Int

    // 値上がりシミュレーション
    let bestCase: YearPair
    let standardCase: YearPair
    let worstCase: YearPair

    // ローン残高
    let loanBalance5yr: Int
    let loanBalance10yr: Int

    // 含み益
    let gainBest: YearPair
    let gainStandard: YearPair
    let gainWorst: YearPair
}

struct YearPair {
    let yr5: Int
    let yr10: Int
}
