import SwiftUI

struct DedupCandidateCard: View {
    let listing: Listing

    private var candidates: [Listing.DedupCandidate] {
        listing.parsedDedupCandidates
    }

    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("同じ物件の可能性あり")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                    Spacer()
                    AIIndicator()
                }

                ForEach(candidates) { candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.name)
                                .font(.caption)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(sourceDisplayName(candidate.source))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let price = candidate.priceMan {
                                    Text("\(price)万円")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                }
                                Text("確信度: \(Int(candidate.confidence * 100))%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if !candidate.url.isEmpty, let url = URL(string: candidate.url) {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private func sourceDisplayName(_ source: String) -> String {
        switch source {
        case "suumo": return "SUUMO"
        case "homes": return "HOME'S"
        case "rehouse": return "リハウス"
        case "nomucom": return "ノムコム"
        case "athome": return "アットホーム"
        case "stepon": return "住友不動産"
        case "livable": return "東急リバブル"
        default: return source
        }
    }
}
