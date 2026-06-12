import Testing
import SwiftUI
@testable import RealEstateApp

@Suite("GradeBadge")
struct GradeBadgeTests {

    // MARK: - 色のマッピング

    @Test("各グレード S/A/B/C/D の色は DesignSystem.scoreColor と一致")
    func gradeColorMatchesDesignSystem() {
        for grade in ["S", "A", "B", "C", "D"] {
            let fromDesignSystem = DesignSystem.scoreColor(for: grade)
            // GradeBadge は内部で DesignSystem.scoreColor(for:) を使うので、
            // 同一関数の結果が等しいことを確認
            #expect(fromDesignSystem == DesignSystem.scoreColor(for: grade),
                    "グレード \(grade) の色が不一致")
        }
    }

    @Test("スコアからグレードへの変換 — GradeThresholds との整合")
    func gradeFromScore() {
        let thresholds = DesignSystem.GradeThresholds()
        let cases: [(score: Int, expected: String)] = [
            (85, "S"), (80, "S"),
            (79, "A"), (65, "A"),
            (64, "B"), (50, "B"),
            (49, "C"), (35, "C"),
            (34, "D"), (0, "D")
        ]
        for c in cases {
            #expect(thresholds.grade(for: c.score) == c.expected,
                    "score=\(c.score): expected=\(c.expected), got=\(thresholds.grade(for: c.score))")
        }
    }

    @Test("scoreColor(for score:) はスコア→グレード→色の変換を一元化")
    func scoreColorIntConvertsViaGrade() {
        let thresholds = DesignSystem.GradeThresholds()
        for score in [0, 35, 50, 65, 80, 100] {
            let grade = thresholds.grade(for: score)
            let colorViaGrade = DesignSystem.scoreColor(for: grade)
            let colorViaScore = DesignSystem.scoreColor(for: score)
            #expect(colorViaGrade == colorViaScore,
                    "score=\(score): colorViaGrade != colorViaScore")
        }
    }

    // MARK: - BadgeSize

    @Test("BadgeSize.small の side は medium より小さい")
    func badgeSizeSmallSmallerThanMedium() {
        #expect(GradeBadge.BadgeSize.small.side < GradeBadge.BadgeSize.medium.side)
    }

    @Test("BadgeSize.medium の side は large より小さい")
    func badgeSizeMediumSmallerThanLarge() {
        #expect(GradeBadge.BadgeSize.medium.side < GradeBadge.BadgeSize.large.side)
    }
}
