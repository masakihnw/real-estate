import SwiftUI

struct ExtractedFeaturesSection: View {
    let features: Listing.ExtractedFeatures

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI抽出情報", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                AIIndicator()
            }

            if let reno = features.renovationHistory {
                FeatureRow(icon: "hammer.fill", label: "リノベーション", value: reno, color: .blue)
            }

            if let mgmt = features.managementQuality {
                FeatureRow(
                    icon: "building.2.fill",
                    label: "管理状態",
                    value: mgmt,
                    color: managementColor(mgmt)
                )
            }

            if let equipment = features.equipmentHighlights, !equipment.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("設備")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(equipment, id: \.self) { item in
                            Text(item)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }

            if let negatives = features.negativeFactors, !negatives.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("注意点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(negatives, id: \.self) { item in
                            Text(item)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.08))
                                .foregroundStyle(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }

            if let notable = features.notablePoints {
                FeatureRow(icon: "star.fill", label: "注目", value: notable, color: .yellow)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
    }

    private func managementColor(_ quality: String) -> Color {
        switch quality {
        case "管理優良": return .green
        case "管理良好": return .blue
        case "管理注意": return .orange
        default: return .secondary
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
            }
        }
    }
}

