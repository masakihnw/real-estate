import SwiftUI

struct SwipeCardView: View {
    let listing: Listing
    let dragOffset: CGSize
    let isTopCard: Bool
    /// ボタン/ジェスチャ確定時に強制表示するスタンプ（dragOffset 駆動と OR）。
    var forcedStamp: SwipeDecision?

    @State private var imageIndex = 0
    @State private var deck: SwipeCardImageBuilder.Deck = .empty

    private var swipeProgress: Double {
        guard isTopCard else { return 0 }
        return Double(dragOffset.width) / 150
    }

    private static func buildDeck(for listing: Listing) -> SwipeCardImageBuilder.Deck {
        SwipeCardImageBuilder.build(
            thumbnailURL: listing.thumbnailURL,
            suumoImages: listing.parsedSuumoImages.compactMap { img in
                img.resolvedURL.map { (url: $0, label: img.label) }
            },
            floorPlanImages: listing.parsedFloorPlanImages
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            imageCarousel
            infoSection
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .overlay(alignment: .topLeading) {
            if swipeProgress > 0.3 || forcedStamp == .like {
                stampLabel("LIKE", color: .green, rotation: -15)
                    .opacity(forcedStamp == .like ? 1 : min(1, swipeProgress))
                    .padding(24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if swipeProgress < -0.3 || forcedStamp == .nope {
                stampLabel("NOPE", color: .orange, rotation: 15)
                    .opacity(forcedStamp == .nope ? 1 : min(1, -swipeProgress))
                    .padding(24)
            }
        }
        .overlay(alignment: .top) {
            if forcedStamp == .skip {
                stampLabel("あとで", color: .gray, rotation: -8)
                    .padding(.top, 40)
            }
        }
        .onAppear { buildImagesIfNeeded() }
        .onChange(of: listing.identityKey) { _, _ in
            imageIndex = 0
            deck = Self.buildDeck(for: listing)
        }
        .onChange(of: listing.suumoImagesJSON) { _, _ in rebuildAfterDetailFetch() }
        // 軽量フィードは間取り URL を持たず、詳細取得で後追い設定される。
        // 間取り JSON 更新でも再構築して小窓・カルーセルに反映する。
        .onChange(of: listing.floorPlanImagesJSON) { _, _ in rebuildAfterDetailFetch() }
    }

    private func rebuildAfterDetailFetch() {
        deck = Self.buildDeck(for: listing)
        if imageIndex >= deck.images.count { imageIndex = 0 }
    }

    // MARK: - Image Carousel

    private var imageCarousel: some View {
        GeometryReader { geo in
            let images = deck.images
            let w = geo.size.width
            let h = w * 0.65

            ZStack(alignment: .bottom) {
                let safeIndex = min(imageIndex, max(images.count - 1, 0))
                if images.isEmpty {
                    placeholder.frame(width: w, height: h)
                } else {
                    TrimmedAsyncImage(
                        url: images[safeIndex].url,
                        width: w,
                        height: h
                    )
                    .id(imageIndex)
                }

                // Tap zones for prev/next
                if images.count > 1 {
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .overlay(alignment: .leading) {
                                if imageIndex > 0 {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .padding(10)
                                }
                            }
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    imageIndex = max(0, imageIndex - 1)
                                }
                            }
                        Color.clear
                            .contentShape(Rectangle())
                            .overlay(alignment: .trailing) {
                                if imageIndex < images.count - 1 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .padding(10)
                                }
                            }
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    imageIndex = min(images.count - 1, imageIndex + 1)
                                }
                            }
                    }
                    .frame(width: w, height: h)
                }

                // Progress dots
                if images.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<min(images.count, 10), id: \.self) { i in
                            Capsule()
                                .fill(i == imageIndex ? Color.white : Color.white.opacity(0.5))
                                .frame(width: i == imageIndex ? 16 : 6, height: 4)
                        }
                        if images.count > 10 {
                            Text("+\(images.count - 10)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.bottom, 8)
                }

                // Image label
                if !images.isEmpty {
                    HStack {
                        Spacer()
                        Text(images[safeIndex].label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.5))
                            .clipShape(Capsule())
                            .padding(8)
                    }
                    .frame(maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .overlay(alignment: .bottomLeading) {
                badgeOverlay
            }
            .overlay(alignment: .bottomTrailing) {
                floorPlanInset(safeIndex: min(imageIndex, max(images.count - 1, 0)))
            }
        }
        .aspectRatio(1 / 0.65, contentMode: .fit)
    }

    /// メイン画像に常時併記する間取り図の小窓。タップでカルーセルを間取り図へジャンプする。
    /// すでに間取り図を表示中のときは重複を避けて隠す。
    @ViewBuilder
    private func floorPlanInset(safeIndex: Int) -> some View {
        if let fpIndex = deck.floorPlanIndex,
           deck.images.indices.contains(fpIndex),
           deck.images.indices.contains(safeIndex),
           !deck.images[safeIndex].isFloorPlan {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { imageIndex = fpIndex }
            } label: {
                VStack(spacing: 0) {
                    TrimmedAsyncImage(url: deck.images[fpIndex].url, width: 74, height: 56)
                    Text("間取り")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                }
                .frame(width: 74)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white.opacity(0.9), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel("間取り図を拡大")
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
    }

    private var badgeOverlay: some View {
        HStack(spacing: 6) {
            if let grade = listing.scoreGradeLetter, let score = listing.listingScore {
                ScoreBadge(grade: grade, value: score)
            }
            if let badge = listing.highlightBadge {
                HighlightBadgeView(text: badge)
            }
        }
        .padding(10)
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(listing.nameWithFloor)
                .font(.headline)
                .lineLimit(2)

            Text(listing.priceDisplayCompact)
                .font(.title3.bold())
                .foregroundStyle(Color.accentColor)

            HStack(spacing: 0) {
                let specs = [listing.layout, listing.areaDisplay, listing.walkDisplay, listing.builtAgeDisplay]
                    .compactMap { $0 == "—" ? nil : $0 }
                ForEach(Array(specs.enumerated()), id: \.offset) { index, spec in
                    if index > 0 {
                        Text(" · ")
                            .foregroundStyle(.tertiary)
                    }
                    Text(spec)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let station = listing.displayStationLine {
                Text(station)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            aiSummarySection
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lifecycle

    private func buildImagesIfNeeded() {
        if deck.images.isEmpty {
            deck = Self.buildDeck(for: listing)
        }
    }

    // MARK: - AI Summary

    @ViewBuilder
    private var aiSummarySection: some View {
        if let score = listing.aiRecommendationScore {
            Divider()
                .padding(.vertical, 2)
            recommendationContent(score: score)
        } else if let summary = listing.displayAISummary {
            Divider()
                .padding(.vertical, 2)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.indigo)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 星＋ラベル＋フラグ＋結論＋アクション（詳細画面 InvestmentSummaryCard と同じ構成）。
    private func recommendationContent(score: Int) -> some View {
        let flags = listing.parsedRecommendationFlags
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= score ? "star.fill" : "star")
                            .font(.system(size: 12))
                            .foregroundStyle(i <= score
                                ? AIRecommendationStyle.starColor(forScore: score)
                                : Color.secondary.opacity(0.3))
                    }
                }
                Text(AIRecommendationStyle.label(forScore: score))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(AIRecommendationStyle.starColor(forScore: score))
                Spacer()
                AIIndicator()
            }

            if !flags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(flags, id: \.self) { flag in
                        Text(flag)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(AIRecommendationStyle.flagColor(for: flag).opacity(0.12))
                            .foregroundStyle(AIRecommendationStyle.flagColor(for: flag))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }

            if let conclusion = listing.displayAISummary {
                Text(conclusion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action = listing.aiRecommendationAction, !action.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.caption)
                    Text(action)
                        .font(.caption)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Stamp

    private func stampLabel(_ text: String, color: Color, rotation: Double) -> some View {
        Text(text)
            .font(.system(size: 40, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color, lineWidth: 4)
            )
            .rotationEffect(.degrees(rotation))
    }
}
