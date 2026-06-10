import SwiftUI

struct AlternateSourcesSection: View {
    let listing: Listing

    private var altPrices: [Listing.AlternateSourcePrice] {
        listing.parsedAltSourcePrices
    }

    /// 本物件 + 他サイトの (表示名, 価格, URL) 一覧
    private var allRows: [(name: String, priceMan: Int?, url: String?)] {
        var rows: [(String, Int?, String?)] = [
            (sourceDisplayName(listing.source ?? "") + "（本物件）", listing.priceMan, nil)
        ]
        for alt in altPrices {
            rows.append((sourceDisplayName(alt.source), alt.priceMan, alt.url))
        }
        return rows
    }

    var body: some View {
        if !altPrices.isEmpty {
            comparisonCard
        } else if listing.duplicateCount <= 1 {
            exclusiveCard
        }
    }

    // MARK: - サイト別価格比較カード

    private var comparisonCard: some View {
        let rows = allRows
        let prices = rows.map { $0.priceMan.map(Double.init) }
        let cheapest = ComparisonHighlight.bestIndex(prices, higherIsBetter: false)
        let maxPrice = rows.compactMap(\.priceMan).max() ?? 1

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("サイト別の掲載価格", systemImage: "link")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                AIIndicator()
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.caption)
                        .foregroundStyle(idx == 0 ? .primary : .secondary)
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)

                    if let price = row.priceMan {
                        // 価格バー（最大価格比）
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.08))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(idx == cheapest ? Color.green.opacity(0.7) : Color.blue.opacity(0.4))
                                    .frame(width: max(4, geo.size.width * CGFloat(price) / CGFloat(maxPrice)))
                            }
                        }
                        .frame(height: 8)

                        Text(formatPrice(price))
                            .font(.caption.weight(idx == cheapest ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(idx == cheapest ? .green : .primary)
                            .frame(width: 76, alignment: .trailing)

                        if idx == cheapest {
                            Text("最安")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green))
                        }
                    } else {
                        Text("価格非公開")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    if let urlString = row.url, !urlString.isEmpty, let url = URL(string: urlString) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
    }

    // MARK: - 独占掲載カード

    /// 他サイトに掲載がない物件は競合の目に触れにくい「掘り出し物」候補
    private var exclusiveCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sourceDisplayName(listing.source ?? "本サイト")) のみ掲載")
                    .font(.caption.weight(.semibold))
                Text("他サイト未掲載の独占物件。競合が気づきにくい掘り出し物の可能性")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple.opacity(0.06))
        )
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
}
