import SwiftUI

struct InvestmentSummaryCard: View {
    let listing: Listing

    @State private var isEvidenceExpanded = false

    private var hasRecommendation: Bool { listing.aiRecommendationScore != nil }
    private var summary: String? { listing.displayAISummary }
    private var badge: String? { listing.highlightBadge }
    private var strengths: [String] { listing.parsedKeyStrengths }
    private var risks: [String] { listing.parsedKeyRisks }

    var body: some View {
        if hasRecommendation {
            recommendationCard
        } else if summary != nil || badge != nil {
            legacySummaryCard
        }
    }

    // MARK: - AI Recommendation Card

    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                recommendationStarsView
                Spacer()
                AIIndicator()
            }

            if let conclusion = summary {
                Text(conclusion)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let flags = listing.parsedRecommendationFlags
            if !flags.isEmpty {
                recommendationFlagsView(flags: flags)
            }

            // 判断の根拠（フラグに対応する一次データを展開表示）
            let evidenceList = RecommendationEvidence.evidenceList(for: listing)
            if !evidenceList.isEmpty {
                DisclosureGroup(isExpanded: $isEvidenceExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(evidenceList, id: \.flag) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.flag)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(flagColor(for: item.flag))
                                    .frame(width: 92, alignment: .leading)
                                Text(item.evidence)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.caption2)
                        Text("判断の根拠")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }

            if let action = listing.aiRecommendationAction, !action.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.caption)
                    Text(action)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(recommendationBorderColor, lineWidth: 1)
        )
    }

    private var recommendationStarsView: some View {
        HStack(spacing: 2) {
            let score = listing.aiRecommendationScore ?? 0
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= score ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(i <= score ? starColor(for: score) : Color.secondary.opacity(0.3))
            }
            Text(recommendationLabel)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(starColor(for: score))
                .padding(.leading, 4)
        }
    }

    private func recommendationFlagsView(flags: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(flags, id: \.self) { flag in
                Text(flag)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(flagColor(for: flag).opacity(0.12))
                    .foregroundStyle(flagColor(for: flag))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private var recommendationLabel: String {
        AIRecommendationStyle.label(forScore: listing.aiRecommendationScore)
    }

    private func starColor(for score: Int) -> Color {
        AIRecommendationStyle.starColor(forScore: score)
    }

    private func flagColor(for flag: String) -> Color {
        AIRecommendationStyle.flagColor(for: flag)
    }

    private var recommendationBorderColor: Color {
        AIRecommendationStyle.borderColor(forScore: listing.aiRecommendationScore)
    }

    // MARK: - Legacy Card

    private var legacySummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let badge {
                    HighlightBadgeView(text: badge)
                }
                Spacer()
                AIIndicator()
            }

            if let summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }

            if !strengths.isEmpty || !risks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !strengths.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("この物件の強み")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            ForEach(strengths, id: \.self) { s in
                                Label(s, systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    if !risks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("注意点")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            ForEach(risks, id: \.self) { r in
                                Label(r, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }
}

struct AIIndicator: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
            Text("AI")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
