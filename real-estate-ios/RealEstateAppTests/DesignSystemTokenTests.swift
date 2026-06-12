import Testing
import SwiftUI
@testable import RealEstateApp

@Suite("DesignSystem Tokens v2 (DS)")
struct DesignSystemTokenTests {

    // MARK: - Spacing

    @Test("Spacing は全て 4pt グリッドの倍数")
    func spacingMultipleOf4() {
        let values: [CGFloat] = [
            DS.Spacing.xs, DS.Spacing.sm, DS.Spacing.md,
            DS.Spacing.lg, DS.Spacing.xl, DS.Spacing.xxl
        ]
        for v in values {
            #expect(v.truncatingRemainder(dividingBy: 4) == 0,
                    "Spacing \(v) は4の倍数でない")
        }
    }

    @Test("Spacing: xs < sm < md < lg < xl < xxl")
    func spacingOrdered() {
        #expect(DS.Spacing.xs  < DS.Spacing.sm)
        #expect(DS.Spacing.sm  < DS.Spacing.md)
        #expect(DS.Spacing.md  < DS.Spacing.lg)
        #expect(DS.Spacing.lg  < DS.Spacing.xl)
        #expect(DS.Spacing.xl  < DS.Spacing.xxl)
    }

    @Test("Spacing.xs が最小値 4")
    func spacingXsIs4() {
        #expect(DS.Spacing.xs == 4)
    }

    // MARK: - Radius

    @Test("Radius: chip < card < sheet")
    func radiusOrdered() {
        #expect(DS.Radius.chip  < DS.Radius.card)
        #expect(DS.Radius.card  < DS.Radius.sheet)
    }

    @Test("Radius.chip == 8, card == 16, sheet == 24")
    func radiusExactValues() {
        #expect(DS.Radius.chip  ==  8)
        #expect(DS.Radius.card  == 16)
        #expect(DS.Radius.sheet == 24)
    }

    // MARK: - Opacity

    @Test("Opacity 値は全て (0, 1) の範囲")
    func opacityInRange() {
        let values: [Double] = [
            DS.Opacity.tintBg, DS.Opacity.border,
            DS.Opacity.disabled, DS.Opacity.overlay
        ]
        for v in values {
            #expect(v > 0 && v < 1, "Opacity \(v) が (0, 1) 範囲外")
        }
    }

    @Test("Opacity: tintBg < border < disabled < overlay")
    func opacityOrdered() {
        #expect(DS.Opacity.tintBg   < DS.Opacity.border)
        #expect(DS.Opacity.border   < DS.Opacity.disabled)
        #expect(DS.Opacity.disabled < DS.Opacity.overlay)
    }

    // MARK: - Shadow

    @Test("Shadow.card は Shadow.floating より軽い")
    func shadowCardLighterThanFloating() {
        #expect(DS.Shadow.card.opacity < DS.Shadow.floating.opacity)
        #expect(DS.Shadow.card.radius  < DS.Shadow.floating.radius)
    }

    @Test("Shadow の opacity は正の値")
    func shadowOpacityPositive() {
        #expect(DS.Shadow.card.opacity > 0)
        #expect(DS.Shadow.floating.opacity > 0)
    }

    @Test("Shadow の radius は正の値")
    func shadowRadiusPositive() {
        #expect(DS.Shadow.card.radius > 0)
        #expect(DS.Shadow.floating.radius > 0)
    }

    // MARK: - Grade (DesignSystem.GradeThresholds)

    @Test("GradeThresholds: スコア → グレード変換（デフォルト閾値）")
    func gradeDefaultThresholds() {
        let t = DesignSystem.GradeThresholds()
        #expect(t.grade(for: 100) == "S")
        #expect(t.grade(for: 80)  == "S")
        #expect(t.grade(for: 79)  == "A")
        #expect(t.grade(for: 65)  == "A")
        #expect(t.grade(for: 64)  == "B")
        #expect(t.grade(for: 50)  == "B")
        #expect(t.grade(for: 49)  == "C")
        #expect(t.grade(for: 35)  == "C")
        #expect(t.grade(for: 34)  == "D")
        #expect(t.grade(for: 0)   == "D")
    }

    @Test("GradeThresholds: カスタム閾値")
    func gradeCustomThresholds() {
        let t = DesignSystem.GradeThresholds(s: 90, a: 70, b: 50, c: 30)
        #expect(t.grade(for: 95) == "S")
        #expect(t.grade(for: 89) == "A")
        #expect(t.grade(for: 69) == "B")
        #expect(t.grade(for: 49) == "C")
        #expect(t.grade(for: 29) == "D")
    }

    @Test("scoreColor(for score:) はスコア→グレード→色 の一元化変換")
    func scoreColorFromIntMatchesGrade() {
        // スコア 82 → S（デフォルト閾値 s=80）→ scoreS
        let fromScore = DesignSystem.scoreColor(for: 82)
        let fromGrade = DesignSystem.scoreColor(for: "S")
        #expect(fromScore == fromGrade)

        // スコア 70 → A（65<=70<80）
        let fromScore2 = DesignSystem.scoreColor(for: 70)
        let fromGrade2 = DesignSystem.scoreColor(for: "A")
        #expect(fromScore2 == fromGrade2)
    }

    @Test("不明グレード → デフォルト色 (scoreC と同値)")
    func unknownGradeReturnsDefault() {
        let knownC   = DesignSystem.scoreColor(for: "C")
        let unknown  = DesignSystem.scoreColor(for: "Z")
        #expect(knownC == unknown)
    }
}
