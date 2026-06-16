//
//  TodayView.swift
//  RealEstateApp
//
//  「今日」タブ（朝刊型ホーム）。旧 DashboardView（9セクション常設）を置き換える。
//  構成: ブリーフ → 変化カード（横スクロール最大5枚）→ スワイプ入口 →
//        週次相場（折りたたみ）→ すべての動きを見る
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Query(filter: #Predicate<Listing> { !$0.isDelisted && $0.propertyType == "chuko" })
    private var activeListings: [Listing]
    @State private var selectedListing: Listing?
    /// AIデイリーブリーフ（当日分のみ。なければ TodayDigest のローカル合成を表示）
    @State private var aiBrief: DailyBrief?

    var body: some View {
        // 単一パス集計を body 先頭で1度だけ実行（旧 DashboardStats と同じパターン）
        let pendingCount = SwipeSessionViewModel.pendingCount(from: activeListings)
        let digest = TodayDigest(
            listings: activeListings,
            reviewedBuildingNames: BuildingPreferenceStore.shared.reviewedBuildingNames,
            pendingSwipeCount: pendingCount
        )

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    briefHeader(digest)
                    if !digest.changeCards.isEmpty {
                        changeCardsSection(digest)
                    }
                    if pendingCount > 0 {
                        swipeEntryCard(pendingCount)
                    }
                    weeklyMarketSection(digest)
                    activityLink
                }
                .padding(DS.Spacing.lg)
            }
            .navigationTitle("今日")
            .fullScreenCover(item: $selectedListing) { listing in
                ListingDetailPagerView(listings: [listing], initialIndex: 0)
            }
            // 日跨ぎで id が変わると再フェッチされる（body 再評価時に評価）。
            // 表示側でも isFresh を再判定するため、stale なブリーフは表示されない
            .task(id: DailyBriefService.todayKey()) {
                aiBrief = await DailyBriefService.fetchLatest()
            }
        }
    }

    // MARK: - ブリーフ（今日のひとこと）

    /// 表示時点で当日分（JST）の AI ブリーフ。stale なら nil → ローカル合成へフォールバック
    private var freshAIBrief: DailyBrief? {
        guard let brief = aiBrief,
              DailyBriefService.isFresh(briefDate: brief.briefDate) else { return nil }
        return brief
    }

    private func briefHeader(_ digest: TodayDigest) -> some View {
        let ai = freshAIBrief
        return HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: briefIcon(digest, hasAI: ai != nil))
                .font(DS.Typography.sectionTitle)
                .foregroundStyle(ai != nil || !digest.hasNoChanges ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(ai?.summaryText ?? digest.briefText)
                    .font(DS.Typography.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if ai != nil {
                    Text("AIブリーフ")
                        .font(DS.Typography.badge)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardGlassBackground()
        .accessibilityLabel("今日のひとこと: \(ai?.summaryText ?? digest.briefText)")
    }

    private func briefIcon(_ digest: TodayDigest, hasAI: Bool) -> String {
        if hasAI { return "sparkles" }
        return digest.hasNoChanges ? "moon.zzz" : "sun.max.fill"
    }

    // MARK: - 変化カード

    private func changeCardsSection(_ digest: TodayDigest) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("今日の動き")
                .font(DS.Typography.sectionTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: DS.Spacing.md) {
                    ForEach(digest.changeCards) { card in
                        ChangeCardView(card: card) {
                            selectedListing = card.listing
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    // MARK: - スワイプ入口

    private func swipeEntryCard(_ pendingCount: Int) -> some View {
        Button {
            HapticManager.soft()
            NotificationCenter.default.post(name: .didRequestSwipeSession, object: nil)
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("未評価\(pendingCount)件をスワイプ")
                        .font(DS.Typography.sectionTitle)
                        .foregroundStyle(.primary)
                    Text("新着物件を仕分けして探索精度を上げる")
                        .font(DS.Typography.label)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(DS.Typography.label)
                    .foregroundStyle(.tertiary)
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardGlassBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("未評価\(pendingCount)件をスワイプで仕分ける")
    }

    // MARK: - 週次相場（折りたたみ）

    private func weeklyMarketSection(_ digest: TodayDigest) -> some View {
        SectionCard(
            title: "今週の相場",
            systemImage: "chart.bar",
            isCollapsible: true,
            initiallyExpanded: false
        ) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                scoreDistribution(digest.scoreGrades)
                if !digest.wardRankings.isEmpty {
                    Divider()
                    wardRanking(digest.wardRankings)
                }
            }
        }
    }

    private func scoreDistribution(_ grades: TodayDigest.ScoreGrades) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("おすすめ度分布")
                .font(DS.Typography.label)
                .foregroundStyle(.secondary)
            ForEach(
                [("S", grades.s), ("A", grades.a), ("B", grades.b), ("C", grades.c), ("D", grades.d)],
                id: \.0
            ) { grade, count in
                HStack(spacing: DS.Spacing.sm) {
                    GradeBadge(grade: grade, size: .small)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: DS.Radius.chip / 2)
                            .fill(DesignSystem.scoreColor(for: grade).opacity(DS.Opacity.border))
                            .frame(
                                width: geo.size.width * CGFloat(count) / CGFloat(grades.maxCount)
                            )
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    Text("\(count)")
                        .font(DS.Typography.label)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                }
                .frame(height: 22)
            }
        }
    }

    private func wardRanking(_ rankings: [TodayDigest.WardRanking]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("エリア平均スコア Top5")
                .font(DS.Typography.label)
                .foregroundStyle(.secondary)
            ForEach(Array(rankings.enumerated()), id: \.element) { index, ranking in
                HStack(spacing: DS.Spacing.sm) {
                    Text("\(index + 1)")
                        .font(DS.Typography.badge)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(ranking.ward)
                        .font(DS.Typography.body)
                    Spacer()
                    Text("平均\(ranking.avgScore)点・\(ranking.count)件")
                        .font(DS.Typography.label)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - すべての動き

    private var activityLink: some View {
        NavigationLink {
            ActivityFeedView()
        } label: {
            HStack {
                Label("すべての動きを見る", systemImage: "list.bullet.rectangle")
                    .font(DS.Typography.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(DS.Typography.label)
                    .foregroundStyle(.tertiary)
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardGlassBackground()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 変化カード（1枚）

private struct ChangeCardView: View {
    let card: TodayDigest.ChangeCard
    let onTap: () -> Void

    private var listing: Listing { card.listing }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                thumbnail
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(listing.name)
                        .font(DS.Typography.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: DS.Spacing.sm) {
                        if let price = listing.priceMan {
                            PriceText(priceMan: price, style: .compact)
                        }
                        if let change = listing.latestPriceChange, change != 0 {
                            DeltaBadge(deltaMan: change)
                        }
                        if let grade = listing.scoreGradeLetter {
                            GradeBadge(grade: grade, size: .small)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.md)
            }
            .frame(width: 240)
            .cardGlassBackground()
        }
        .buttonStyle(.plain)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .contextMenu {
            Button {
                Task {
                    await BuildingPreferenceStore.shared.setPreference(
                        listing.preferenceKey, preference: .like
                    )
                    HapticManager.success()
                }
            } label: {
                Label("いいね", systemImage: "heart")
            }
            Button(role: .destructive) {
                Task {
                    await BuildingPreferenceStore.shared.setPreference(
                        listing.preferenceKey, preference: .nope
                    )
                }
            } label: {
                Label("見送り", systemImage: "hand.thumbsdown")
            }
            if let url = URL(string: listing.url) {
                ShareLink(item: url) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
            }
        }
        .accessibilityLabel("\(card.kind.label): \(listing.name)")
    }

    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            if let url = listing.thumbnailURL {
                TrimmedAsyncImage(url: url, width: 240, height: 150)
            } else {
                ZStack {
                    Color(.systemGray6)
                    Image(systemName: "building.2")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 240, height: 150)
            }
            Label(card.kind.label, systemImage: card.kind.systemImage)
                .font(DS.Typography.badge)
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .background(.black.opacity(DS.Opacity.overlay), in: Capsule())
                .padding(DS.Spacing.sm)
        }
    }
}

#Preview {
    TodayView()
        .environment(ListingStore.shared)
        .modelContainer(for: [Listing.self], inMemory: true)
}
