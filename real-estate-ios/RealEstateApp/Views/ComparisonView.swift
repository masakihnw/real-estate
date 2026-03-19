//
//  ComparisonView.swift
//  RealEstateApp
//
//  選択した物件を横並びで比較する。
//

import SwiftUI
import UIKit

struct ComparisonView: View {
    let listings: [Listing]
    @Environment(\.dismiss) private var dismiss

    @State private var showShareSheet = false
    @State private var showAIComparison = false
    @State private var pdfFileURL: URL?

    // 比較行の表示フラグを事前計算（body 内で何度も contains(where:) を呼ぶのを回避）
    private var showProfitPct: Bool { listings.contains { $0.ssProfitPct != nil } }
    private var showAppreciationRate: Bool { listings.contains { $0.ssAppreciationRate != nil } }
    private var showPriceJudgment: Bool { listings.contains { $0.computedPriceJudgment != nil } }
    private var showMarketData: Bool { listings.contains { $0.hasMarketData } }
    private var showPopulationData: Bool { listings.contains { $0.hasPopulationData } }

    var body: some View {
        if listings.count < 2 {
            ContentUnavailableView {
                Label("比較には2件以上選択してください", systemImage: "rectangle.on.rectangle")
            } description: {
                Text("物件一覧で比較モードをオンにし、2件以上選択してから比較を実行してください。")
            }
        } else {
            NavigationStack {
                comparisonGrid
                    .accessibilityLabel("物件比較表")
                    .accessibilityHint("横にスワイプして全物件を比較できます")
                    .navigationTitle("物件比較")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { dismiss() }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 12) {
                                Button {
                                    showAIComparison = true
                                } label: {
                                    Label("AIで比較", systemImage: "brain")
                                }
                                Button {
                                    exportPDF()
                                } label: {
                                    Label("PDF出力", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                    .sheet(isPresented: $showAIComparison) {
                        AIComparisonSheet(listings: listings)
                    }
                    .sheet(isPresented: $showShareSheet) {
                        if let url = pdfFileURL {
                            ShareSheet(items: [url])
                        }
                    }
            }
        }
    }

    // MARK: - 比較テーブル

    private var comparisonGrid: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                headerRow
                basicRows
                optionalRows
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        GridRow {
            Text("")
                .frame(width: 90, alignment: .leading)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground))
                .accessibilityLabel("比較表ヘッダー")
            ForEach(listings, id: \.url) { listing in
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
                .frame(width: 140, alignment: .leading)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    @ViewBuilder
    private var basicRows: some View {
        comparisonRow("価格", values: listings.map(\.priceDisplay))
        comparisonRow("面積", values: listings.map(\.areaDisplay))
        comparisonRow("間取り", values: listings.map { $0.layout ?? "—" })
        comparisonRow("最寄駅", values: listings.map { $0.stationName ?? "—" })
        comparisonRow("徒歩", values: listings.map(\.walkDisplay))
        comparisonRow("築年", values: listings.map { $0.isShinchiku ? $0.deliveryDateDisplay : $0.builtAgeDisplay })
        comparisonRow("階数", values: listings.map { $0.floorDisplay.isEmpty ? "—" : $0.floorDisplay })
        comparisonRow("総戸数", values: listings.map(\.totalUnitsDisplay))
        comparisonRow("権利形態", values: listings.map(\.ownershipShort))
    }

    @ViewBuilder
    private var optionalRows: some View {
        if showProfitPct {
            comparisonRow("儲かる確率", values: listings.map(\.ssProfitDisplay))
        }
        if showAppreciationRate {
            comparisonRow("値上がり率", values: listings.map { $0.ssAppreciationRate.map { String(format: "%.1f%%", $0) } ?? "—" })
        }
        if showPriceJudgment {
            comparisonRow("割安判定", values: listings.map { $0.computedPriceJudgment ?? "—" })
        }
        if showMarketData {
            comparisonRow("成約相場比", values: listings.map { $0.parsedMarketData?.priceRatioDisplay ?? "—" })
            comparisonRow("相場差額", values: listings.map { $0.parsedMarketData?.priceDiffDisplay ?? "—" })
            comparisonRow("エリア傾向", values: listings.map { $0.parsedMarketData?.trendDisplay ?? "—" })
        }
        if showPopulationData {
            comparisonRow("エリア人口", values: listings.map { $0.parsedPopulationData?.populationDisplay ?? "—" })
            comparisonRow("人口増減", values: listings.map { $0.parsedPopulationData?.popChange1yrDisplay ?? "—" })
        }
    }

    /// Grid の1行。ラベル列 + 各物件の値列で構成。行高は Grid が自動同期。
    private func comparisonRow(_ label: String, values: [String]) -> some View {
        GridRow {
            labelCell(label)
                .frame(width: 90)
            ForEach(Array(values.enumerated()), id: \.offset) { _, val in
                valueCell(val)
                    .frame(width: 140)
            }
        }
    }

    private func exportPDF() {
        guard let data = PDFExporter.generateComparisonPDF(listings: listings) else { return }
        let fileName = "物件比較_\(Date().timeIntervalSince1970).pdf"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: tempURL)
            pdfFileURL = tempURL
            showShareSheet = true
        } catch {
            // 書き込み失敗時は共有シートを表示しない
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

// MARK: - ShareSheet（UIActivityViewController ラッパー）

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
