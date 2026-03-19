//
//  AIComparisonSheet.swift
//  RealEstateApp
//
//  複数物件の比較プロンプトを生成し、生成 AI で比較評価を依頼するシート。
//  ComparisonView のツールバーから表示する。
//

import SwiftUI

struct AIComparisonSheet: View {
    let listings: [Listing]
    @Environment(\.dismiss) private var dismiss
    @State private var copiedType: CopiedType?
    @State private var showBuyerProfileSheet = false
    @State private var buyerProfile: BuyerProfile = .empty
    @State private var floorPlanEntries: [(name: String, image: UIImage)] = []
    @State private var floorPlanCopied = false
    @State private var isLoadingFloorPlans = false

    private enum CopiedType: Equatable {
        case markdown
        case ai(AIService)
    }

    private var hasAnyFloorPlan: Bool { listings.contains(where: \.hasFloorPlanImages) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    listingSummary
                    buyerProfileButton
                    markdownCopyButton

                    if hasAnyFloorPlan {
                        floorPlanCopyButton
                    }

                    Divider()

                    Text("AI サービスで比較")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb.min")
                        if hasAnyFloorPlan && !floorPlanEntries.isEmpty {
                            Text("プロンプトを貼り付け後、戻って間取り図をコピー → 貼り付けで添付")
                        } else {
                            Text("プロンプトをコピーしてAIアプリを開きます → 貼り付けてください")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 2)

                    ForEach(AIService.allCases, id: \.rawValue) { service in
                        aiServiceButton(service)
                    }
                }
                .padding(16)
            }
            .navigationTitle("AI で比較")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onAppear { buyerProfile = BuyerProfile.load() }
            .task { await loadFloorPlanImages() }
            .sheet(isPresented: $showBuyerProfileSheet, onDismiss: { buyerProfile = BuyerProfile.load() }) {
                BuyerProfileSheet()
            }
        }
    }

    // MARK: - ヘッダー

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("複数物件の AI 比較", systemImage: "brain")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)

            Text("\(listings.count)件の物件情報を生成 AI に渡し、対等に比較・ランキングしてもらいます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 比較対象リスト

    private var listingSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(listings.enumerated()), id: \.element.url) { index, listing in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(listing.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text("\(listing.priceDisplayCompact)　\(listing.areaDisplay)　\(listing.primaryStationDisplay)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }

    // MARK: - 買い手条件ボタン

    private var buyerProfileButton: some View {
        Button {
            showBuyerProfileSheet = true
        } label: {
            HStack {
                Image(systemName: buyerProfile.isEmpty ? "person.badge.plus" : "person.fill.checkmark")
                VStack(alignment: .leading, spacing: 2) {
                    Text(buyerProfile.isEmpty ? "買い手条件を設定" : "買い手条件を編集")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(buyerProfile.isEmpty
                         ? "設定するとAIがあなたの状況に即した比較をします"
                         : "設定済み — プロンプトに自動反映されます")
                        .font(.caption2)
                        .foregroundStyle(buyerProfile.isEmpty ? .orange : .green)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(buyerProfile.isEmpty ? Color.orange.opacity(0.06) : Color.green.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 間取り図まとめコピーボタン

    @ViewBuilder
    private var floorPlanCopyButton: some View {
        Button {
            guard !floorPlanEntries.isEmpty else { return }
            if let composite = compositeFloorPlanImage() {
                UIPasteboard.general.image = composite
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.3)) { floorPlanCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.3)) { floorPlanCopied = false }
            }
        } label: {
            HStack {
                if isLoadingFloorPlans {
                    ProgressView()
                        .controlSize(.small)
                    Text("間取り図を読み込み中…")
                } else {
                    Image(systemName: floorPlanCopied ? "checkmark" : "photo.on.rectangle")
                    Text(floorPlanCopied
                         ? "間取り図をコピーしました（\(floorPlanEntries.count)件分）"
                         : "間取り図をまとめてコピー（\(floorPlanEntries.count)件分・1枚に合成）")
                }
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(floorPlanCopied ? .green : .orange)
        .disabled(floorPlanEntries.isEmpty || isLoadingFloorPlans)
    }

    /// 各間取り図を物件名ラベル付きで横並びに合成した1枚の画像を生成
    private func compositeFloorPlanImage() -> UIImage? {
        guard !floorPlanEntries.isEmpty else { return nil }

        let labelHeight: CGFloat = 40
        let padding: CGFloat = 16
        let spacing: CGFloat = 12
        let maxCellWidth: CGFloat = 600

        let cellWidth = min(maxCellWidth, floorPlanEntries.map { $0.image.size.width }.max() ?? maxCellWidth)
        let scaledHeights: [CGFloat] = floorPlanEntries.map { entry in
            let scale = cellWidth / entry.image.size.width
            return entry.image.size.height * scale
        }
        let maxImageHeight = scaledHeights.max() ?? 400

        let cellHeight = labelHeight + maxImageHeight
        let totalWidth = padding + CGFloat(floorPlanEntries.count) * cellWidth + CGFloat(floorPlanEntries.count - 1) * spacing + padding
        let totalHeight = padding + cellHeight + padding

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: totalHeight))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: UIColor.darkGray
            ]

            for (i, entry) in floorPlanEntries.enumerated() {
                let x = padding + CGFloat(i) * (cellWidth + spacing)

                let label = "[\(i + 1)] \(entry.name)" as NSString
                let labelRect = CGRect(x: x, y: padding, width: cellWidth, height: labelHeight)
                label.draw(in: labelRect, withAttributes: labelAttrs)

                let scale = cellWidth / entry.image.size.width
                let imgW = cellWidth
                let imgH = entry.image.size.height * scale
                let imgY = padding + labelHeight + (maxImageHeight - imgH) / 2
                entry.image.draw(in: CGRect(x: x, y: imgY, width: imgW, height: imgH))
            }
        }
    }

    private func loadFloorPlanImages() async {
        guard hasAnyFloorPlan else { return }
        isLoadingFloorPlans = true
        var entries: [(name: String, image: UIImage)] = []
        for listing in listings {
            guard let url = listing.parsedFloorPlanImages.first else { continue }
            let cacheKey = url.absoluteString
            if let cached = TrimmedImageCache.shared.image(for: cacheKey) {
                entries.append((name: listing.name, image: cached))
                continue
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let original = UIImage(data: data) else { continue }
                let trimmed = original.trimmingWhitespaceBorder()
                TrimmedImageCache.shared.set(trimmed, for: cacheKey)
                entries.append((name: listing.name, image: trimmed))
            } catch {
                continue
            }
        }
        floorPlanEntries = entries
        isLoadingFloorPlans = false
    }

    // MARK: - Markdown コピーボタン

    private var markdownCopyButton: some View {
        Button {
            let md = listings.enumerated().map { i, l in "## 物件\(i + 1)\n\n\(l.toMarkdown())" }.joined(separator: "\n---\n\n")
            UIPasteboard.general.string = md
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.3)) { copiedType = .markdown }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    if copiedType == .markdown { copiedType = nil }
                }
            }
        } label: {
            HStack {
                Image(systemName: copiedType == .markdown ? "checkmark" : "doc.on.doc")
                Text(copiedType == .markdown ? "コピーしました" : "物件情報のみコピー（Markdown）")
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(copiedType == .markdown ? .green : .accentColor)
    }

    // MARK: - AI サービスボタン

    private func aiServiceButton(_ service: AIService) -> some View {
        Button {
            openAIService(service)
        } label: {
            HStack(spacing: 10) {
                serviceLogoView(service)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(service.rawValue) で比較")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if copiedType == .ai(service) {
                        Text("プロンプトをコピーしました → 貼り付けてください")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Text("比較プロンプトをコピーして\(service.rawValue)を開きます")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(copiedType == .ai(service) ? service.color.opacity(0.08) : Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func serviceLogoView(_ service: AIService) -> some View {
        let img = UIImage(named: service.logoAsset)
        if let img {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: service.fallbackIcon)
                .font(.body)
                .foregroundStyle(service.color)
        }
    }

    // MARK: - AI サービス起動

    private func openAIService(_ service: AIService) {
        let prompt = Listing.toAIComparisonPrompt(listings: listings, buyerProfile: buyerProfile)

        UIPasteboard.general.string = prompt

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.3)) { copiedType = .ai(service) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            service.openApp(prompt: prompt)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                if copiedType == .ai(service) { copiedType = nil }
            }
        }
    }
}
