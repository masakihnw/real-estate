import SwiftUI

struct InvestmentSummaryCard: View {
    let listing: Listing

    private var summary: String? { listing.investmentSummary }
    private var badge: String? { listing.highlightBadge }
    private var strengths: [String] { listing.parsedKeyStrengths }
    private var risks: [String] { listing.parsedKeyRisks }

    var body: some View {
        if summary != nil || badge != nil {
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
