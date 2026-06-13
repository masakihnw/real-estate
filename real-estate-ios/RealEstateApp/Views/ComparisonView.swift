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

    var body: some View {
        if listings.count < 2 {
            ContentUnavailableView {
                Label("比較には2件以上選択してください", systemImage: "rectangle.on.rectangle")
            } description: {
                Text("物件一覧で比較モードをオンにし、2件以上選択してから比較を実行してください。")
            }
        } else {
            NavigationStack {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        // ポートフォリオ比較: 候補のレーダーチャートを重ね描き
                        let radarEntries = MultiRadarChartView.entries(from: listings)
                        if radarEntries.count >= 2 {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("評価バランス比較", systemImage: "hexagon")
                                    .font(.subheadline.weight(.semibold))
                                MultiRadarChartView(entries: radarEntries)
                                    .frame(maxWidth: 320)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                        }

                        comparisonGrid
                    }
                }
                    .accessibilityLabel("物件比較表")
                    .accessibilityHint("縦にスクロールして全項目を比較できます")
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

    // MARK: - 比較テーブル（縦スクロール・物件を列に項目を行に。横スクロール廃止 §3.6）

    private var comparisonGrid: some View {
        VStack(spacing: 0) {
            headerCards
            ForEach(ComparisonRowBuilder.rows(for: listings)) { row in
                comparisonRow(row)
            }
        }
        .padding(.horizontal, 12)
    }

    private let labelWidth: CGFloat = 76

    /// 各物件のヘッダーカード（名前＋グレードバッジ＋スコア）を横並び。スコアは行にせずここで表示。
    private var headerCards: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: labelWidth, height: 1)
            ForEach(listings, id: \.url) { listing in
                VStack(alignment: .leading, spacing: 4) {
                    Text(listing.nameWithFloor)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let grade = listing.scoreGradeLetter {
                            Text(grade)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(DesignSystem.scoreColor(for: grade))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        if let score = listing.listingScore {
                            Text("\(score)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 比較表の1行。ラベル列 + 各物件の値セル（均等幅）。best=緑+crown / worst=赤。
    private func comparisonRow(_ row: ComparisonRowData) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            ForEach(Array(row.values.enumerated()), id: \.offset) { idx, val in
                valueCell(val, emphasis: idx == row.bestIndex ? .best : (idx == row.worstIndex ? .worst : nil))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    private enum CellEmphasis { case best, worst }

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

    private func valueCell(_ text: String, emphasis: CellEmphasis? = nil) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(emphasis == nil ? .caption : .caption.weight(.bold))
                .foregroundStyle(emphasis == .best ? Color.green :
                                 emphasis == .worst ? Color.red : Color.primary)
                .lineLimit(2)
            if emphasis == .best {
                Image(systemName: "crown.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
