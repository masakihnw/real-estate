import SwiftUI

struct SwipeCardView: View {
    let listing: Listing
    let dragOffset: CGSize
    let isTopCard: Bool

    @State private var imageIndex = 0
    @State private var cardImages: [CardImage] = []

    private var swipeProgress: Double {
        guard isTopCard else { return 0 }
        return Double(dragOffset.width) / 150
    }

    private static func buildCardImages(for listing: Listing) -> [CardImage] {
        var images: [CardImage] = []
        if let thumb = listing.thumbnailURL {
            images.append(CardImage(url: thumb, label: "メイン"))
        }
        for img in listing.parsedSuumoImages {
            guard let url = img.resolvedURL, url != listing.thumbnailURL else { continue }
            images.append(CardImage(url: url, label: img.label))
        }
        for url in listing.parsedFloorPlanImages {
            images.append(CardImage(url: url, label: "間取り図"))
        }
        return images
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
            if swipeProgress > 0.3 {
                stampLabel("LIKE", color: .green, rotation: -15)
                    .opacity(min(1, swipeProgress))
                    .padding(24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if swipeProgress < -0.3 {
                stampLabel("NOPE", color: .orange, rotation: 15)
                    .opacity(min(1, -swipeProgress))
                    .padding(24)
            }
        }
        .onAppear { buildImagesIfNeeded() }
        .onChange(of: listing.identityKey) { _, _ in
            imageIndex = 0
            cardImages = Self.buildCardImages(for: listing)
        }
        .onChange(of: listing.suumoImagesJSON) { _, _ in
            cardImages = Self.buildCardImages(for: listing)
            if imageIndex >= cardImages.count { imageIndex = 0 }
        }
    }

    // MARK: - Image Carousel

    private var imageCarousel: some View {
        GeometryReader { geo in
            let images = cardImages
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
        }
        .aspectRatio(1 / 0.65, contentMode: .fit)
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
                ScoreBadge(
                    grade: grade,
                    value: score,
                    isAIAnalyzed: listing.aiRecommendationScore != nil
                )
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
            Text(listing.name)
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
        if cardImages.isEmpty {
            cardImages = Self.buildCardImages(for: listing)
        }
    }

    // MARK: - AI Summary

    @ViewBuilder
    private var aiSummarySection: some View {
        if let summary = listing.investmentSummary ?? listing.aiRecommendationSummary {
            Divider()
                .padding(.vertical, 2)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.indigo)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
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

private struct CardImage: Identifiable {
    let url: URL
    let label: String
    var id: String { url.absoluteString }
}
