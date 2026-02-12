//
//  LoanCalculator.swift
//  RealEstateApp
//
//  ローン残高・含み益シミュレーション計算
//
//  ── アプリの計算条件 ──
//  価格: 9,500万円 / 金利: 0.8% / 返済期間: 50年 / 頭金: 0万円
//
//  住まいサーフィンのサイト条件（6,000万円 / 0.79% / 35年 / 0万円）とは異なる。
//  サイトからは「変動率 (%)」だけを取り込み、予測値・ローン残高・含み益は
//  全てアプリ独自のパラメータで計算する。
//
//  ── 計算ロジック ──
//  1. サイトのシミュレーション絶対値 ÷ サイト基準価格 → 各シナリオの変動率(%)を逆算
//     (絶対値がなければ ss_forecast_change_rate を標準10年とし、±10pp で推定)
//  2. 予測値(万円) = 購入価格 × (1 + 変動率)
//  3. ローン残高 = 元利均等返済で独自計算
//  4. 含み益 = 予測値 − ローン残高
//

import Foundation

/// ローンシミュレーションの計算ユーティリティ
enum LoanCalculator {
    // MARK: - 定数（アプリの計算条件）

    /// 返済期間（年）
    static let termYears: Int = 50
    /// 年利 (%)
    static let annualRate: Double = 0.8
    /// 頭金（万円）
    static let downPayment: Int = 0

    /// 新築物件のデフォルトシミュレーション価格（万円）
    static let defaultShinchikuPrice: Int = 9500

    /// 住まいサーフィンのデフォルトシミュレーション基準価格（万円）
    /// スクレイピングで基準価格を取得できなかった場合のフォールバック
    static let siteDefaultSimPrice: Int = 6000

    /// ベスト/ワースト推定時のスプレッド（百分率ポイント）
    /// 標準 ±10pp を使用（不動産10年予測の一般的な不確実性幅）
    static let scenarioSpreadPP: Double = 10.0

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
    ///
    /// 全ての値をアプリ独自に計算する:
    /// - 変動率: サイトの絶対値から逆算 or ss_forecast_change_rate から推定
    /// - 予測値: 購入価格 × (1 + 変動率)
    /// - ローン残高: 元利均等返済で計算 (0.8% / 50年)
    /// - 含み益: 予測値 − ローン残高
    static func simulate(listing: Listing) -> SimulationResult? {
        guard listing.hasSimulationData else { return nil }

        // ── 購入価格の決定 ──
        let purchasePrice: Int
        if listing.isShinchiku {
            purchasePrice = defaultShinchikuPrice
        } else {
            guard let price = listing.priceMan ?? listing.ssOkiPrice70m2,
                  price > 0 else { return nil }
            purchasePrice = price
        }

        let principal = Double(purchasePrice - downPayment)
        guard principal > 0 else { return nil }

        // ── 変動率の導出 ──
        let rates = deriveAppreciationRates(from: listing)

        // ── 予測値 = 購入価格 × (1 + 変動率) ──
        let best5 = applyRate(to: purchasePrice, rate: rates.best5yr)
        let best10 = applyRate(to: purchasePrice, rate: rates.best10yr)
        let std5 = applyRate(to: purchasePrice, rate: rates.standard5yr)
        let std10 = applyRate(to: purchasePrice, rate: rates.standard10yr)
        let worst5 = applyRate(to: purchasePrice, rate: rates.worst5yr)
        let worst10 = applyRate(to: purchasePrice, rate: rates.worst10yr)

        // ── ローン残高: アプリの条件で計算 ──
        let balance5yr = loanBalance(principal: principal, afterYears: 5)
        let balance10yr = loanBalance(principal: principal, afterYears: 10)

        let bal5 = Int(round(balance5yr))
        let bal10 = Int(round(balance10yr))

        return SimulationResult(
            purchasePrice: purchasePrice,
            // 値上がり (予測売却価格)
            bestCase: .init(yr5: best5, yr10: best10),
            standardCase: .init(yr5: std5, yr10: std10),
            worstCase: .init(yr5: worst5, yr10: worst10),
            // ローン残高
            loanBalance5yr: bal5,
            loanBalance10yr: bal10,
            // 含み益 = 予測売却価格 − ローン残高
            gainBest: .init(yr5: best5 - bal5, yr10: best10 - bal10),
            gainStandard: .init(yr5: std5 - bal5, yr10: std10 - bal10),
            gainWorst: .init(yr5: worst5 - bal5, yr10: worst10 - bal10)
        )
    }

    // MARK: - 変動率の導出

    /// サイトのデータから各シナリオの変動率 (%) を導出する。
    ///
    /// 優先順位:
    ///   1. シミュレーション絶対値がある → 基準価格で割って変動率を逆算
    ///   2. ss_forecast_change_rate のみ → 標準10年レートとし、ベスト/ワーストは ±10pp で推定
    static func deriveAppreciationRates(from listing: Listing) -> AppreciationRates {
        let basePrice = listing.ssSimBasePrice ?? siteDefaultSimPrice

        // ── パス1: シミュレーション絶対値から逆算 ──
        if let b5 = listing.ssSimBest5yr,
           let b10 = listing.ssSimBest10yr,
           let s5 = listing.ssSimStandard5yr,
           let s10 = listing.ssSimStandard10yr,
           let w5 = listing.ssSimWorst5yr,
           let w10 = listing.ssSimWorst10yr,
           basePrice > 0 {
            let bp = Double(basePrice)
            return AppreciationRates(
                best5yr: (Double(b5) / bp - 1) * 100,
                best10yr: (Double(b10) / bp - 1) * 100,
                standard5yr: (Double(s5) / bp - 1) * 100,
                standard10yr: (Double(s10) / bp - 1) * 100,
                worst5yr: (Double(w5) / bp - 1) * 100,
                worst10yr: (Double(w10) / bp - 1) * 100
            )
        }

        // ── パス2: 予測変動率から推定 ──
        let stdRate10 = listing.ssForecastChangeRate ?? 0.0
        let bestRate10 = stdRate10 + scenarioSpreadPP
        let worstRate10 = stdRate10 - scenarioSpreadPP

        return AppreciationRates(
            best5yr: interpolate5yr(from10yr: bestRate10),
            best10yr: bestRate10,
            standard5yr: interpolate5yr(from10yr: stdRate10),
            standard10yr: stdRate10,
            worst5yr: interpolate5yr(from10yr: worstRate10),
            worst10yr: worstRate10
        )
    }

    // MARK: - Private ヘルパー

    /// 10年変動率 → 5年変動率を複利補間で推定
    ///
    /// factor_5yr = factor_10yr^(5/10)
    /// 例: 10年で +20% → 5年で約 +9.5%
    private static func interpolate5yr(from10yr rate: Double) -> Double {
        let factor10 = 1 + rate / 100.0
        // 負の factor の場合でも安全に計算（0 以下にならないようクランプ）
        let clamped = max(factor10, 0.01)
        let factor5 = pow(clamped, 0.5)
        return (factor5 - 1) * 100.0
    }

    /// 変動率を適用して予測価格を計算（万円）
    private static func applyRate(to price: Int, rate: Double) -> Int {
        Int(round(Double(price) * (1 + rate / 100.0)))
    }
}

// MARK: - データ構造

/// 各シナリオの変動率 (%)
struct AppreciationRates {
    let best5yr: Double
    let best10yr: Double
    let standard5yr: Double
    let standard10yr: Double
    let worst5yr: Double
    let worst10yr: Double
}

struct SimulationResult {
    let purchasePrice: Int

    // 値上がりシミュレーション (予測売却価格)
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
