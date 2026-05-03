import SwiftUI

struct AlternateSourcesSection: View {
    let listing: Listing

    private var altPrices: [Listing.AlternateSourcePrice] {
        listing.parsedAltSourcePrices
    }

    var body: some View {
        if !altPrices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("他サイトの掲載価格", systemImage: "link")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    AIIndicator()
                }

                ForEach(altPrices) { alt in
                    HStack {
                        Text(sourceDisplayName(alt.source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)

                        if let price = alt.priceMan {
                            Text(formatPrice(price))
                                .font(.subheadline)
                                .fontWeight(.medium)
                            if let currentPrice = listing.priceMan, currentPrice > 0 {
                                let diff = price - currentPrice
                                if diff != 0 {
                                    Text(formatPriceDiff(diff))
                                        .font(.caption)
                                        .foregroundStyle(diff < 0 ? .green : .red)
                                }
                            }
                        } else {
                            Text("価格非公開")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !alt.url.isEmpty, let url = URL(string: alt.url) {
                            Link(destination: url) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
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

    private func formatPrice(_ man: Int) -> String {
        if man >= 10000 {
            let oku = man / 10000
            let remainder = man % 10000
            if remainder == 0 {
                return "\(oku)億円"
            }
            return "\(oku)億\(remainder)万円"
        }
        return "\(man)万円"
    }

    private func formatPriceDiff(_ diff: Int) -> String {
        let sign = diff > 0 ? "+" : ""
        return "\(sign)\(diff)万"
    }
}
