import SwiftUI

struct ScoreBadge: View {
    let grade: String
    let value: Int
    let isAIAnalyzed: Bool

    init(grade: String, value: Int, isAIAnalyzed: Bool = false) {
        self.grade = grade
        self.value = value
        self.isAIAnalyzed = isAIAnalyzed
    }

    var body: some View {
        HStack(spacing: 4) {
            if isAIAnalyzed {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
            }
            Text(grade)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(DesignSystem.scoreColor(for: grade))
        )
    }
}

#Preview {
    VStack(spacing: 12) {
        HStack(spacing: 8) {
            ScoreBadge(grade: "S", value: 86)
            ScoreBadge(grade: "A", value: 72)
            ScoreBadge(grade: "B", value: 58)
            ScoreBadge(grade: "C", value: 44)
            ScoreBadge(grade: "D", value: 30)
        }
        HStack(spacing: 8) {
            ScoreBadge(grade: "S", value: 86, isAIAnalyzed: true)
            ScoreBadge(grade: "A", value: 72, isAIAnalyzed: true)
            ScoreBadge(grade: "B", value: 58, isAIAnalyzed: true)
            ScoreBadge(grade: "C", value: 44, isAIAnalyzed: true)
            ScoreBadge(grade: "D", value: 30, isAIAnalyzed: true)
        }
    }
    .padding()
}
