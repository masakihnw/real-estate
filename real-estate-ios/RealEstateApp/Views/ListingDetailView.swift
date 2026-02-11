//
//  ListingDetailView.swift
//  RealEstateApp
//
//  HIG・OOUI: 物件オブジェクトの詳細。名詞（物件）を選択したあとの属性表示と、動詞（詳細を開く）アクション。
//

import SwiftUI
import SwiftData
import SafariServices

struct ListingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let listing: Listing
    @State private var editableMemo: String = ""
    @FocusState private var isMemoFocused: Bool
    /// Firestore 書き込みのデバウンス用タスク
    @State private var memoDebounceTask: Task<Void, Never>?
    /// 駅プルダウン展開状態
    @State private var isStationsExpanded: Bool = false
    /// SFSafariViewController 表示用
    @State private var safariURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.detailSectionSpacing) {
                    // 掲載終了バナー
                    if listing.isDelisted {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("この物件はサイトから掲載終了しています")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.cornerRadius, style: .continuous))
                    }

                    // オブジェクトの識別: 名前・住所 ＋ いいね
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(listing.name)
                                .font(.title2)
                                .fontWeight(.semibold)
                            if let addr = listing.address, !addr.isEmpty {
                                Text(addr)
                                    .font(ListingObjectStyle.subtitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                        Button {
                            listing.isLiked.toggle()
                            saveContext()
                            FirebaseSyncService.shared.pushAnnotation(for: listing)
                        } label: {
                            Image(systemName: listing.isLiked ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(listing.isLiked ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(listing.isLiked ? "いいねを解除" : "いいねする")
                    }
                    .accessibilityElement(children: .combine)

                    Divider()

                    // ① メモ
                    VStack(alignment: .leading, spacing: 6) {
                        Text("メモ")
                            .font(ListingObjectStyle.detailLabel)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $editableMemo)
                            .font(ListingObjectStyle.detailValue)
                            .frame(minHeight: 80)
                            .padding(8)
                            .listingGlassBackground()
                            .focused($isMemoFocused)
                            .onChange(of: editableMemo) { _, newValue in
                                listing.memo = newValue.isEmpty ? nil : newValue
                                saveContext()
                                memoDebounceTask?.cancel()
                                memoDebounceTask = Task {
                                    try? await Task.sleep(for: .milliseconds(800))
                                    guard !Task.isCancelled else { return }
                                    FirebaseSyncService.shared.pushAnnotation(for: listing)
                                }
                            }
                    }

                    // ② 住まいサーフィン評価
                    if listing.hasSumaiSurfinData {
                        Divider()
                        sumaiSurfinSection
                    }

                    // 値上がり・含み益シミュレーション
                    if listing.hasSimulationData {
                        Divider()
                        SimulationSectionView(listing: listing)
                    }

                    Divider()

                    // ③ 物件情報（マージ: 旧「物件情報」+「アクセス・権利」を統合）
                    propertyInfoSection

                    // ④ ハザード情報
                    if listing.hasHazardRisk {
                        Divider()
                        hazardSection
                    }

                    Divider()

                    // ⑤ 外部サイトボタン（SFSafariViewController でログイン状態を共有）
                    externalLinksSection
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let shareURL = URL(string: listing.url) {
                        ShareLink(
                            item: shareURL,
                            subject: Text(listing.name),
                            message: Text("\(listing.name) - \(listing.priceDisplay)")
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("共有")
                    }
                }
            }
            .onAppear {
                editableMemo = listing.memo ?? ""
            }
            .onDisappear {
                memoDebounceTask?.cancel()
                memoDebounceTask = nil
                if listing.memo != nil || !(editableMemo.isEmpty) {
                    FirebaseSyncService.shared.pushAnnotation(for: listing)
                }
            }
            .sheet(isPresented: Binding(
                get: { safariURL != nil },
                set: { if !$0 { safariURL = nil } }
            )) {
                if let url = safariURL {
                    SafariView(url: url)
                        .ignoresSafeArea()
                }
            }
        }
    }

    // MARK: - ③ 物件情報（統合セクション + 駅プルダウン）

    @ViewBuilder
    private var propertyInfoSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: DesignSystem.detailGridSpacing) {
            DetailItem(title: "価格", value: listing.priceDisplay)
            DetailItem(title: "専有面積", value: listing.areaDisplay)
            DetailItem(title: "間取り", value: listing.layout ?? "—")
            if listing.isShinchiku {
                DetailItem(title: "引渡時期", value: listing.deliveryDateDisplay)
            } else {
                DetailItem(title: "築年", value: listing.builtDisplay)
                DetailItem(title: "所在階", value: listing.floorPosition.map { "\($0)階" } ?? "—")
            }
            DetailItem(title: "階建", value: listing.floorTotal.map { "\($0)階建" } ?? "—")
            DetailItem(title: "総戸数", value: listing.totalUnits.map { "\($0)戸" } ?? "—")
            if let ownership = listing.ownership, !ownership.isEmpty {
                DetailItem(title: "権利形態", value: ownership)
            }
            DetailItem(title: "種別", value: listing.isShinchiku ? "新築" : "中古")
        }

        // 路線・駅（プルダウン式：最寄駅を表示し、タップで他駅を展開）
        stationSection
    }

    @ViewBuilder
    private var stationSection: some View {
        let stations = listing.parsedStations
        if !stations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // 最寄駅（常に表示）
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isStationsExpanded.toggle()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("最寄駅")
                                .font(ListingObjectStyle.detailLabel)
                                .foregroundStyle(.secondary)
                            Text(stations[0].fullText)
                                .font(ListingObjectStyle.detailValue)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        if stations.count > 1 {
                            VStack(spacing: 2) {
                                Text("他\(stations.count - 1)駅")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Image(systemName: isStationsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .listingGlassBackground()
                }
                .buttonStyle(.plain)

                // 展開部分（他の最寄駅）
                if isStationsExpanded && stations.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(stations.dropFirst()) { station in
                            HStack {
                                Text(station.fullText)
                                    .font(ListingObjectStyle.detailValue)
                                Spacer()
                                if let walk = station.walkMin {
                                    Text("徒歩\(walk)分")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            if station.id != stations.last?.id {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                    .listingGlassBackground()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - ⑤ 外部サイトボタン（SFSafariViewController）

    @ViewBuilder
    private var externalLinksSection: some View {
        VStack(spacing: 8) {
            if let url = URL(string: listing.url) {
                Button {
                    safariURL = url
                } label: {
                    HStack {
                        Image(systemName: "safari")
                        Text("SUUMO/HOME'S で詳細を開く")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("SUUMO または HOME'S で詳細を開く")
            }

            if let ssURL = listing.ssSumaiSurfinURL,
               let url = URL(string: ssURL) {
                Button {
                    safariURL = url
                } label: {
                    HStack {
                        Image(systemName: "chart.bar.xaxis")
                        Text("住まいサーフィンで詳しく見る")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("住まいサーフィンで詳しく見る")
            }
        }
    }

    // MARK: - ハザード情報セクション

    @ViewBuilder
    private var hazardSection: some View {
        let hazard = listing.parsedHazardData
        let labels = hazard.activeLabels

        VStack(alignment: .leading, spacing: 12) {
            // セクションヘッダー
            Label("ハザード情報", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.orange)

            // GSI ハザードマップ vs 東京都地域危険度で分類
            let tokyoPrefixes = ["建物倒壊", "火災", "総合危険度"]
            let gsiItems = labels.filter { item in
                !tokyoPrefixes.contains(where: { item.label.hasPrefix($0) })
            }
            let tokyoItems = labels.filter { item in
                tokyoPrefixes.contains(where: { item.label.hasPrefix($0) })
            }

            if !gsiItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ハザードマップ該当")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(Array(gsiItems.enumerated()), id: \.offset) { _, item in
                            HazardChip(icon: item.icon, label: item.label, severity: item.severity)
                        }
                    }
                }
            }

            if !tokyoItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("東京都地域危険度")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(tokyoItems.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .font(.body)
                                .foregroundStyle(item.severity == .danger ? .red : .orange)
                                .frame(width: 24)
                            Text(item.label)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            // ランクバー
                            HStack(spacing: 2) {
                                let rank = extractRank(from: item.label)
                                ForEach(1...5, id: \.self) { level in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(level <= rank ? rankBarColor(rank) : Color.gray.opacity(0.2))
                                        .frame(width: 16, height: 12)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Text("※ 国土地理院ハザードマップ・東京都地域危険度データに基づく自動判定です")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .listingGlassBackground()
    }

    private func extractRank(from label: String) -> Int {
        // "建物倒壊 ランク3" → 3
        if let last = label.last, let rank = Int(String(last)) {
            return rank
        }
        return 0
    }

    private func rankBarColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return .green
        case 2: return .yellow
        case 3: return .orange
        case 4, 5: return .red
        default: return .gray
        }
    }

    // MARK: - 住まいサーフィン評価セクション

    @ViewBuilder
    private var sumaiSurfinSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // セクションヘッダー
            Label(
                listing.isShinchiku ? "住まいサーフィン評価（新築）" : "住まいサーフィン評価（中古）",
                systemImage: "chart.bar.xaxis"
            )
            .font(.subheadline)
            .fontWeight(.bold)
            .foregroundStyle(Color.accentColor)

            Text("※住まいサーフィンから自動取得したデータです")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if listing.isShinchiku {
                // ── 新築: 儲かる確率 + ランキング ──
                shinchikuSumaiSection
            } else {
                // ── 中古: 沖式時価 + 値上がり率 + レーダーチャート ──
                chukoSumaiSection
            }

            // ランキング（共通）
            if listing.ssStationRank != nil || listing.ssWardRank != nil {
                HStack(spacing: 16) {
                    if let stRank = listing.ssStationRank {
                        rankItem(label: "駅ランキング", value: stRank)
                    }
                    if let wRank = listing.ssWardRank {
                        rankItem(label: "区ランキング", value: wRank)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .listingGlassBackground()
    }

    // MARK: - 中古マンション: 沖式中古時価 + 値上がり率 + レーダーチャート

    @ViewBuilder
    private var chukoSumaiSection: some View {
        // 沖式中古時価（70㎡換算）と値上がり率
        HStack(alignment: .top, spacing: 4) {
            if let price = listing.ssOkiPrice70m2 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("沖式中古時価（70㎡換算）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(price)")
                            .font(.system(.title, design: .rounded).weight(.heavy))
                            .foregroundStyle(Color.accentColor)
                        Text("万円")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor.opacity(0.6))
                    }
                    if let judgment = listing.ssValueJudgment {
                        Text(judgment)
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(judgmentColor(judgment).opacity(0.15))
                            .foregroundStyle(judgmentColor(judgment))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Spacer()
            if let rate = listing.ssAppreciationRate {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("中古値上がり率")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(rate >= 0 ? "+\(String(format: "%.1f", rate))" : String(format: "%.1f", rate))
                            .font(.system(.title2, design: .rounded).weight(.heavy))
                            .foregroundStyle(rate >= 0 ? Color.green : Color.red)
                        Text("%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(rate >= 0 ? Color.green.opacity(0.6) : Color.red.opacity(0.6))
                    }
                }
            }
        }
    }

    // MARK: - 新築マンション: 儲かる確率

    @ViewBuilder
    private var shinchikuSumaiSection: some View {
        if let pct = listing.ssProfitPct {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("沖式儲かる確率")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(pct)")
                            .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                            .foregroundStyle(profitColor(pct))
                        Text("%")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(profitColor(pct))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if let price = listing.ssOkiPrice70m2 {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("沖式新築時価（70㎡換算）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(price)万円")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                    }
                    if let judgment = listing.ssValueJudgment {
                        Text(judgment)
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(judgmentColor(judgment).opacity(0.15))
                            .foregroundStyle(judgmentColor(judgment))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        } else if let price = listing.ssOkiPrice70m2 {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("沖式新築時価（70㎡換算）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(price)万円")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                Spacer()
                if let judgment = listing.ssValueJudgment {
                    Text(judgment)
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(judgmentColor(judgment).opacity(0.15))
                        .foregroundStyle(judgmentColor(judgment))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func rankItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            let parts = value.split(separator: "/")
            if parts.count == 2 {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(parts[0]))
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("/ \(parts[1])件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
    }

    private func profitColor(_ pct: Int) -> Color {
        if pct >= 70 { return .green }
        if pct >= 40 { return .orange }
        return .red
    }

    private func judgmentColor(_ judgment: String) -> Color {
        switch judgment {
        case "割安": return .green
        case "適正": return .secondary
        case "割高": return .red
        default: return .secondary
        }
    }

    private func saveContext() {
        try? modelContext.save()
    }
}

/// ハザードチップ
private struct HazardChip: View {
    let icon: String
    let label: String
    let severity: Listing.HazardSeverity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(severity == .danger ? Color.red : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (severity == .danger ? Color.red : Color.orange).opacity(0.12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 折り返しレイアウト（iOS 16+ 対応）
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// 詳細画面の1属性（ラベル＋値）。HIG: セマンティックな階層。背景は Material で Liquid Glass 風に。
private struct DetailItem: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ListingObjectStyle.detailLabel)
                .foregroundStyle(.secondary)
            Text(value)
                .font(ListingObjectStyle.detailValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .listingGlassBackground()
    }
}

// MARK: - SFSafariViewController ラッパー
/// Safari のログイン状態・Cookie を共有した状態で外部サイトを開く。
/// Link(destination:) だと独立した Safari が開き Cookie が共有されないため、
/// SFSafariViewController を使う。
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = .systemBlue
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Listing.self, configurations: config)
    let sample = Listing(
        url: "https://example.com/1",
        name: "サンプルマンション",
        priceMan: 8000,
        address: "東京都渋谷区〇〇1-2-3",
        stationLine: "JR山手線「原宿」徒歩6分／東京メトロ副都心線「明治神宮前」徒歩8分／東京メトロ千代田線「表参道」徒歩12分",
        walkMin: 6,
        areaM2: 65,
        layout: "2LDK",
        builtYear: 2010,
        totalUnits: 100,
        floorPosition: 5,
        floorTotal: 10,
        ownership: "所有権"
    )
    container.mainContext.insert(sample)
    return ListingDetailView(listing: sample)
        .modelContainer(container)
}
