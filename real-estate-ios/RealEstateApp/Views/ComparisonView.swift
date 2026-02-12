//
//  ComparisonView.swift
//  RealEstateApp
//
//  選択した物件を横並びで比較する。
//

import SwiftUI

struct ComparisonView: View {
    let listings: [Listing]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if listings.count < 2 {
            ContentUnavailableView {
                Label("比較には2件以上選択してください", systemImage: "rectangle.on.rectangle")
            } description: {
                Text("物件一覧で比較モードをオンにし、2件以上選択してから比較を実行してください。")
            }
        } else {
        NavigationStack {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    // ラベル列
                    VStack(alignment: .leading, spacing: 0) {
                        headerCell("")
                            .accessibilityLabel("比較表ヘッダー")
                        labelCell("価格").accessibilityLabel("項目、価格")
                        labelCell("面積").accessibilityLabel("項目、面積")
                        labelCell("間取り").accessibilityLabel("項目、間取り")
                        labelCell("最寄駅").accessibilityLabel("項目、最寄駅")
                        labelCell("徒歩").accessibilityLabel("項目、徒歩")
                        labelCell("築年").accessibilityLabel("項目、築年")
                        labelCell("階数").accessibilityLabel("項目、階数")
                        labelCell("総戸数").accessibilityLabel("項目、総戸数")
                        labelCell("権利形態").accessibilityLabel("項目、権利形態")
                        if listings.contains(where: { $0.ssProfitPct != nil }) {
                            labelCell("儲かる確率").accessibilityLabel("項目、儲かる確率")
                        }
                        if listings.contains(where: { $0.ssAppreciationRate != nil }) {
                            labelCell("値上がり率").accessibilityLabel("項目、値上がり率")
                        }
                        if listings.contains(where: { $0.ssValueJudgment != nil }) {
                            labelCell("割安判定").accessibilityLabel("項目、割安判定")
                        }
                        if listings.contains(where: { $0.hasMarketData }) {
                            labelCell("成約相場比").accessibilityLabel("項目、成約相場比")
                        }
                        if listings.contains(where: { $0.hasMarketData }) {
                            labelCell("相場差額").accessibilityLabel("項目、相場差額")
                        }
                        if listings.contains(where: { $0.hasMarketData }) {
                            labelCell("エリア傾向").accessibilityLabel("項目、エリア傾向")
                        }
                        if listings.contains(where: { $0.hasPopulationData }) {
                            labelCell("エリア人口").accessibilityLabel("項目、エリア人口")
                        }
                        if listings.contains(where: { $0.hasPopulationData }) {
                            labelCell("人口増減").accessibilityLabel("項目、人口増減")
                        }
                    }
                    .frame(width: 90)

                    // 物件列
                    ForEach(listings, id: \.url) { listing in
                        VStack(alignment: .leading, spacing: 0) {
                            // ヘッダー: 物件名
                            VStack(alignment: .leading, spacing: 2) {
                                Text(listing.name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .lineLimit(2)
                                if listing.isShinchiku {
                                    Text("新築")
                                        .font(.caption2)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(DesignSystem.shinchikuPriceColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(.secondarySystemGroupedBackground))

                            valueCell(listing.priceDisplay)
                            valueCell(listing.areaDisplay)
                            valueCell(listing.layout ?? "—")
                            valueCell(listing.stationName ?? "—")
                            valueCell(listing.walkDisplay)
                            valueCell(listing.isShinchiku ? listing.deliveryDateDisplay : listing.builtAgeDisplay)
                            valueCell(listing.floorDisplay)
                            valueCell(listing.totalUnitsDisplay)
                            valueCell(listing.ownershipShort)
                            if listings.contains(where: { $0.ssProfitPct != nil }) {
                                valueCell(listing.ssProfitDisplay)
                            }
                            if listings.contains(where: { $0.ssAppreciationRate != nil }) {
                                valueCell(listing.ssAppreciationRate.map { String(format: "%.1f%%", $0) } ?? "—")
                            }
                            if listings.contains(where: { $0.ssValueJudgment != nil }) {
                                valueCell(listing.ssValueJudgment ?? "—")
                            }
                            if listings.contains(where: { $0.hasMarketData }) {
                                valueCell(listing.parsedMarketData?.priceRatioDisplay ?? "—")
                            }
                            if listings.contains(where: { $0.hasMarketData }) {
                                valueCell(listing.parsedMarketData?.priceDiffDisplay ?? "—")
                            }
                            if listings.contains(where: { $0.hasMarketData }) {
                                valueCell(listing.parsedMarketData?.trendDisplay ?? "—")
                            }
                            if listings.contains(where: { $0.hasPopulationData }) {
                                valueCell(listing.parsedPopulationData?.populationDisplay ?? "—")
                            }
                            if listings.contains(where: { $0.hasPopulationData }) {
                                valueCell(listing.parsedPopulationData?.popChange1yrDisplay ?? "—")
                            }
                        }
                        .frame(width: 140)

                        if listing.url != listings.last?.url {
                            Divider()
                        }
                    }
                }
            }
            .accessibilityLabel("物件比較表")
            .accessibilityHint("横にスワイプして全物件を比較できます")
            .navigationTitle("物件比較")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        }
    }

    private func headerCell(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(.secondarySystemGroupedBackground))
    }

    private func labelCell(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .bottom) { Divider() }
    }

    private func valueCell(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Divider() }
    }
}
