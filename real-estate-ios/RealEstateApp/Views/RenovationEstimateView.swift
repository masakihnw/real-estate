import SwiftUI

/// リノベーション費用概算ビュー
struct RenovationEstimateView: View {
    let listing: Listing

    @State private var selectedItems: Set<String> = []

    private static let renovationItems: [(id: String, name: String, unitCostRange: String, perM2Low: Int, perM2High: Int)] = [
        ("full", "フルリノベーション", "15〜25万/m²", 150_000, 250_000),
        ("kitchen", "キッチン交換", "80〜200万", 0, 0),
        ("bath", "浴室リフォーム", "60〜150万", 0, 0),
        ("toilet", "トイレ交換", "15〜40万", 0, 0),
        ("floor", "フローリング張替", "3〜6万/m²", 30_000, 60_000),
        ("wall", "壁紙張替", "1〜2万/m²", 10_000, 20_000),
        ("window", "内窓設置", "5〜15万/箇所", 0, 0),
        ("aircon", "エアコン設置（3台）", "30〜60万", 0, 0),
    ]

    private static let fixedCosts: [(String, Int, Int)] = [
        ("kitchen", 800_000, 2_000_000),
        ("bath", 600_000, 1_500_000),
        ("toilet", 150_000, 400_000),
        ("window", 250_000, 750_000),
        ("aircon", 300_000, 600_000),
    ]

    private var areaM2: Double { listing.areaM2 ?? 70 }

    private var estimateLow: Int {
        var total = 0
        for item in selectedItems {
            if let perM2 = Self.renovationItems.first(where: { $0.id == item }) {
                if perM2.perM2Low > 0 {
                    total += Int(Double(perM2.perM2Low) * areaM2)
                } else if let fixed = Self.fixedCosts.first(where: { $0.0 == item }) {
                    total += fixed.1
                }
            }
        }
        return total
    }

    private var estimateHigh: Int {
        var total = 0
        for item in selectedItems {
            if let perM2 = Self.renovationItems.first(where: { $0.id == item }) {
                if perM2.perM2High > 0 {
                    total += Int(Double(perM2.perM2High) * areaM2)
                } else if let fixed = Self.fixedCosts.first(where: { $0.0 == item }) {
                    total += fixed.2
                }
            }
        }
        return total
    }

    var body: some View {
        NavigationStack {
            List {
                Section("物件情報") {
                    HStack {
                        Text("専有面積")
                        Spacer()
                        Text(String(format: "%.1f m²", areaM2))
                            .foregroundStyle(.secondary)
                    }
                    if let builtYear = listing.builtYear {
                        HStack {
                            Text("築年数")
                            Spacer()
                            Text("\(Calendar.current.component(.year, from: Date()) - builtYear)年")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("リノベーション項目を選択") {
                    ForEach(Self.renovationItems, id: \.id) { item in
                        Button {
                            if selectedItems.contains(item.id) {
                                selectedItems.remove(item.id)
                                if item.id == "full" {
                                    selectedItems.subtract(["floor", "wall", "kitchen", "bath", "toilet"])
                                }
                            } else {
                                selectedItems.insert(item.id)
                                if item.id == "full" {
                                    selectedItems.subtract(["floor", "wall", "kitchen", "bath", "toilet"])
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedItems.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedItems.contains(item.id) ? .blue : .secondary)
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                        .font(.subheadline)
                                    Text(item.unitCostRange)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !selectedItems.isEmpty {
                    Section("概算") {
                        HStack {
                            Text("費用レンジ")
                                .font(.headline)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(formatMan(estimateLow)) 〜 \(formatMan(estimateHigh))")
                                    .font(.headline)
                                    .foregroundStyle(.blue)
                                if let price = listing.priceMan {
                                    let totalLow = price + estimateLow / 10000
                                    let totalHigh = price + estimateHigh / 10000
                                    Text("取得総額: \(Listing.formatPriceCompact(totalLow))〜\(Listing.formatPriceCompact(totalHigh))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Text("※ 概算値です。実際の費用は施工会社の見積もりをご確認ください")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("リノベーション費用")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func formatMan(_ yen: Int) -> String {
        Listing.formatPriceCompact(yen / 10000)
    }
}
