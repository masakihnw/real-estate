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
    /// コメント入力テキスト
    @State private var newCommentText: String = ""
    @FocusState private var isCommentFocused: Bool
    /// 編集中のコメントID（nil なら新規投稿モード）
    @State private var editingCommentId: String?
    /// 駅プルダウン展開状態
    @State private var isStationsExpanded: Bool = false
    /// 周辺物件プルダウン展開状態
    @State private var isSurroundingExpanded: Bool = false
    /// 割安判定プルダウン展開状態
    @State private var isPriceJudgmentsExpanded: Bool = false
    /// SFSafariViewController 表示用
    @State private var safariURL: URL?
    /// HIG: 破壊的操作の確認用（コメント削除）
    @State private var deletingCommentId: String?
    /// 通勤時間計算中フラグ
    @State private var isCalculatingCommute = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.detailSectionSpacing) {
                    // 掲載終了バナー
                    delistedBanner

                    // ① 物件名（いいねボタンはナビバーに移動）
                    Text(listing.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // ② 住所（Google Maps アイコンボタン）— ss_address 優先
                    addressSection

                    Divider()

                    // ③ コメント（家族間共有）
                    commentSection

                    Divider()

                    // ④ 内見写真
                    PhotoSectionView(listing: listing)

                    // ④-b 間取り図（SUUMO/HOME'S の物件詳細ページから取得した間取り図画像）
                    if listing.hasFloorPlanImages {
                        Divider()
                        floorPlanSection
                    }

                    Divider()

                    // ⑤ 物件情報（マージ: 旧「物件情報」+「アクセス・権利」を統合）
                    propertyInfoSection

                    // ⑥ 月額支払いシミュレーション（中古・新築共通）
                    if let priceMan = listing.priceMan, priceMan > 0 {
                        MonthlyPaymentSimulationView(listing: listing)
                    }

                    // ⑦ 通勤時間
                    if listing.hasCommuteInfo {
                        Divider()
                        commuteSection
                    } else if listing.hasCoordinate {
                        Divider()
                        commuteCalculateSection
                    }

                    Divider()

                    // ⑧ 住まいサーフィン評価
                    if listing.hasSumaiSurfinData {
                        sumaiSurfinSection
                    } else {
                        sumaiSurfinUnavailableNotice
                    }

                    // ⑧-b 周辺相場（住まいサーフィン）
                    if listing.hasSurroundingProperties {
                        Divider()
                        surroundingPropertiesSection
                            .padding(14)
                            .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
                    }

                    // ⑨ 値上がり・含み益シミュレーション
                    if listing.hasSimulationData {
                        Divider()
                        SimulationSectionView(listing: listing)
                    }

                    // ⑩ 成約相場との比較（不動産情報ライブラリ）
                    if listing.hasMarketData {
                        Divider()
                        MarketDataSectionView(listing: listing)
                    }

                    // ⑪ エリア人口動態（e-Stat）
                    if listing.hasPopulationData {
                        Divider()
                        PopulationSectionView(listing: listing)
                    }

                    // ⑫ ハザード情報（低ランクでもデータがあれば表示）
                    if listing.hasHazardData {
                        Divider()
                        hazardSection
                    }

                    Divider()

                    // ⑬ 外部サイトボタン or 掲載終了メッセージ
                    if listing.isDelisted {
                        delistedNotice
                    } else {
                        externalLinksSection
                    }
                }
                .padding(.horizontal, 14)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
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
                        // HTML準拠: ナビバー右に♥ボタン
                        Button {
                            listing.isLiked.toggle()
                            saveContext()
                            FirebaseSyncService.shared.pushLikeState(for: listing)
                        } label: {
                            Image(systemName: listing.isLiked ? "heart.fill" : "heart")
                                .font(.title3)
                                .foregroundStyle(listing.isLiked ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(listing.isLiked ? "いいねを解除" : "いいねする")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
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

    // MARK: - 掲載終了バナー（画面上部）

    @ViewBuilder
    private var delistedBanner: some View {
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
    }

    // MARK: - ② 住所（Google Maps アイコンボタン）

    @ViewBuilder
    private var addressSection: some View {
        if let addr = listing.bestAddress, !addr.isEmpty {
            HStack(spacing: 8) {
                Text(addr)
                    .font(ListingObjectStyle.subtitle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    let query = (addr + " " + listing.name).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? listing.name
                    if let url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(query)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Image(systemName: "map.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Google Maps で物件を検索")
            }
        }
    }

    // MARK: - ③ 物件情報（最寄駅 + 属性グリッド）

    @ViewBuilder
    private var propertyInfoSection: some View {
        // 最寄駅（物件情報の先頭項目として表示）
        stationSection

        VStack(spacing: 0) {
            DetailRow(title: "価格", value: listing.priceDisplay, accentValue: true)
            if let dupText = listing.duplicateCountDisplay {
                DetailRow(title: "売出戸数", value: dupText)
            }
            DetailRow(title: "間取り / 面積", value: {
                let layout = listing.layout ?? "—"
                let area = listing.areaDisplay
                return "\(layout) / \(area)"
            }())
            if listing.isShinchiku {
                DetailRow(title: "入居時期", value: listing.deliveryDateDisplay)
            } else {
                DetailRow(title: "築年", value: listing.builtDisplay)
            }
            DetailRow(title: listing.isShinchiku ? "階建" : "所在階 / 階建", value: {
                if listing.isShinchiku {
                    return listing.floorTotalDisplay
                } else {
                    let floor = listing.floorPosition.map { "\($0)階" } ?? "—"
                    let total = listing.floorTotal.map { "\($0)階建" } ?? "—"
                    return "\(floor) / \(total)"
                }
            }())
            DetailRow(title: "総戸数", value: listing.totalUnits.map { "\($0)戸" } ?? "—")
            if let ownership = listing.ownership, !ownership.isEmpty {
                HStack {
                    Text("権利形態")
                        .font(ListingObjectStyle.detailLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    OwnershipBadge(listing: listing, size: .large)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            DetailRow(title: "種別", value: listing.isShinchiku ? "新築マンション" : "中古マンション")
        }
        .listingGlassBackground()
    }

    @ViewBuilder
    private var stationSection: some View {
        let stations = listing.parsedStations
        if !stations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // メイン行：ラベル左、駅名+徒歩右（DetailRow と同じレイアウト）
                Button {
                    if stations.count > 1 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isStationsExpanded.toggle()
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("最寄駅")
                                .font(ListingObjectStyle.detailLabel)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if stations.count > 1 {
                                HStack(spacing: 4) {
                                    Text("他\(stations.count - 1)駅")
                                        .font(.caption2)
                                    Image(systemName: isStationsExpanded ? "chevron.up" : "chevron.down")
                                        .font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        Text(stations[0].fullText)
                            .font(ListingObjectStyle.detailValue)
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

    // MARK: - 間取り図セクション

    /// フルスクリーン表示用の間取り図 URL
    @State private var fullScreenFloorPlanURL: URL?

    @ViewBuilder
    private var floorPlanSection: some View {
        let images = listing.parsedFloorPlanImages

        VStack(alignment: .leading, spacing: 10) {
            Label("間取り図", systemImage: "square.split.2x2")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)

            if images.count == 1 {
                // 1枚の場合: フル幅で表示
                floorPlanImage(url: images[0])
            } else {
                // 複数の場合: 横スクロール
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images, id: \.absoluteString) { url in
                            floorPlanImage(url: url)
                                .frame(width: 280)
                        }
                    }
                }
            }

            Text("※ \(listing.source == "homes" ? "HOME'S" : "SUUMO") の物件詳細ページから取得した間取り図です")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenFloorPlanURL != nil },
            set: { if !$0 { fullScreenFloorPlanURL = nil } }
        )) {
            if let url = fullScreenFloorPlanURL {
                FloorPlanFullScreenView(url: url)
            }
        }
    }

    @ViewBuilder
    private func floorPlanImage(url: URL) -> some View {
        Button {
            fullScreenFloorPlanURL = url
        } label: {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .failure:
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title3)
                        Text("画像を読み込めません")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                case .empty:
                    ZStack {
                        Color(.systemGray6)
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                @unknown default:
                    EmptyView()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("間取り図を拡大表示")
    }

    // MARK: - ① コメントセクション

    @ViewBuilder
    private var commentSection: some View {
        let comments = listing.parsedComments
        let currentUserId = FirebaseSyncService.shared.currentUserId

        VStack(alignment: .leading, spacing: 10) {
            // ヘッダー
            HStack {
                Label("コメント", systemImage: "bubble.left.and.bubble.right")
                    .font(ListingObjectStyle.detailLabel)
                    .foregroundStyle(.secondary)
                if !comments.isEmpty {
                    Text("(\(comments.count))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // コメント一覧
            if comments.isEmpty {
                Text("コメントはまだありません")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                // アバター（名前の頭文字）
                                Text(String(comment.authorName.prefix(1)))
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(avatarColor(for: comment.authorId))
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(comment.authorName)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        if comment.isEdited {
                                            Text("(編集済み)")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Text(relativeTime(comment.isEdited ? (comment.editedAt ?? comment.createdAt) : comment.createdAt))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(comment.text)
                                        .font(.subheadline)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                // 自分のコメントのみ編集・削除ボタン
                                if comment.authorId == currentUserId {
                                    HStack(spacing: 12) {
                                        Button {
                                            editingCommentId = comment.id
                                            newCommentText = comment.text
                                            isCommentFocused = true
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("コメントを編集")

                                        Button {
                                            deletingCommentId = comment.id
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("コメントを削除")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)

                        if comment.id != comments.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(8)
                .listingGlassBackground()
            }

            // 入力欄（認証済みの場合のみ）— iMessage 風カプセル入力バー
            if FirebaseSyncService.shared.isAuthenticated {
                VStack(alignment: .leading, spacing: 6) {
                    // 編集中インジケーター
                    if editingCommentId != nil {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.caption2)
                            Text("コメントを編集中")
                                .font(.caption2)
                            Spacer()
                            Button {
                                cancelEditing()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                    }

                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(editingCommentId != nil ? "コメントを編集..." : "コメントを入力...", text: $newCommentText, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(1...4)
                            .focused($isCommentFocused)

                        Button {
                            if let commentId = editingCommentId {
                                // 編集モード: 既存コメントを更新
                                FirebaseSyncService.shared.editComment(
                                    for: listing,
                                    commentId: commentId,
                                    newText: newCommentText,
                                    modelContext: modelContext
                                )
                            } else {
                                // 新規投稿モード
                                FirebaseSyncService.shared.addComment(
                                    for: listing,
                                    text: newCommentText,
                                    modelContext: modelContext
                                )
                            }
                            newCommentText = ""
                            editingCommentId = nil
                            isCommentFocused = false
                        } label: {
                            Image(systemName: editingCommentId != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    .white,
                                    newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Color(.systemGray4)
                                        : Color.accentColor
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(editingCommentId != nil ? "編集を保存" : "コメントを送信")
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(editingCommentId != nil ? Color.accentColor : Color(.systemGray4), lineWidth: 1)
                    )
                }
            } else {
                Text("コメントするにはログインしてください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // HIG: 破壊的操作には確認ダイアログを表示
        .alert("コメントを削除しますか？", isPresented: Binding(
            get: { deletingCommentId != nil },
            set: { if !$0 { deletingCommentId = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let commentId = deletingCommentId {
                    FirebaseSyncService.shared.deleteComment(
                        for: listing,
                        commentId: commentId,
                        modelContext: modelContext
                    )
                }
                deletingCommentId = nil
            }
            Button("キャンセル", role: .cancel) {
                deletingCommentId = nil
            }
        } message: {
            Text("この操作は取り消せません。")
        }
    }

    /// 編集モードをキャンセルして新規投稿モードに戻す
    private func cancelEditing() {
        editingCommentId = nil
        newCommentText = ""
        isCommentFocused = false
    }

    /// ユーザー ID から一貫したアバター色を生成
    private func avatarColor(for userId: String) -> Color {
        guard !userId.isEmpty else { return .gray }
        let hash = abs(userId.hashValue)
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]
        return colors[hash % colors.count]
    }

    /// 相対時間表示（例: "3時間前", "昨日"）
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        return formatter
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - 掲載終了メッセージ

    @ViewBuilder
    private var delistedNotice: some View {
        VStack(spacing: 4) {
            Text("この物件はSUUMO/HOME'Sから削除されました。")
            Text("掲載時の情報を表示しています。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    // MARK: - 通勤時間セクション

    @ViewBuilder
    private var commuteSection: some View {
        let commute = listing.parsedCommuteInfo

        VStack(alignment: .leading, spacing: 12) {
            // セクションヘッダー
            Label("通勤時間", systemImage: "tram.fill")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)

            // Playground
            if let pg = commute.playground {
                Button {
                    CommuteTimeService.openGoogleMaps(from: listing, to: .playground)
                } label: {
                    commuteDestinationCard(
                        name: "Playground株式会社",
                        minutes: pg.minutes,
                        summary: pg.summary,
                        transfers: pg.transfers,
                        color: DesignSystem.commutePGColor,
                        logoImage: "logo-playground"
                    )
                }
                .buttonStyle(CommuteCardButtonStyle())
                .accessibilityLabel("Playground株式会社への通勤経路を Google Maps で開く")
            }

            // エムスリーキャリア
            if let m3 = commute.m3career {
                Button {
                    CommuteTimeService.openGoogleMaps(from: listing, to: .m3career)
                } label: {
                    commuteDestinationCard(
                        name: "エムスリーキャリア株式会社",
                        minutes: m3.minutes,
                        summary: m3.summary,
                        transfers: m3.transfers,
                        color: DesignSystem.commuteM3Color,
                        logoImage: "logo-m3career"
                    )
                }
                .buttonStyle(CommuteCardButtonStyle())
                .accessibilityLabel("エムスリーキャリアへの通勤経路を Google Maps で開く")
            }

            // フォールバック概算の場合は再計算ボタン
            if commute.hasFallbackEstimate {
                Button {
                    guard !isCalculatingCommute else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    isCalculatingCommute = true
                    Task {
                        await CommuteTimeService.shared.calculateForListing(listing, modelContext: modelContext)
                        saveContext()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isCalculatingCommute = false
                        }
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(
                            listing.parsedCommuteInfo.hasFallbackEstimate ? .warning : .success
                        )
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isCalculatingCommute {
                            ProgressView()
                                .controlSize(.small)
                            Text("再検索中...")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("正確な経路を再検索")
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isCalculatingCommute)
            }

            // 注釈
            VStack(alignment: .leading, spacing: 2) {
                Text("※ Apple Maps の公共交通機関経路に基づく自動計算です")
                Text("※ 平日朝 8:00 出発での最適経路")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
        .animation(.easeInOut(duration: 0.2), value: isCalculatingCommute)
    }

    @ViewBuilder
    private func commuteDestinationCard(
        name: String,
        minutes: Int,
        summary: String,
        transfers: Int?,
        color: Color,
        logoImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 会社名
            HStack(alignment: .center, spacing: 8) {
                Image(logoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 20)

                Text(name)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                // 所要時間（大きく表示）
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(minutes)")
                            .font(.system(.title2, design: .rounded).weight(.heavy))
                            .foregroundStyle(color)
                        Text("分")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(color.opacity(0.7))
                    }
                    if let t = transfers, t > 0 {
                        Text("乗換\(t)回")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 経路概要
            if !summary.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    // 外部リンクアイコン（タップ可能であることを示す）
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(color.opacity(0.45))
                }
                .padding(.leading, 32)
            }
        }
        .padding(10)
        .background(color.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 通勤時間が未計算の場合の計算ボタン
    @ViewBuilder
    private var commuteCalculateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("通勤時間", systemImage: "tram.fill")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)

            Button {
                guard !isCalculatingCommute else { return }
                // 押下時の触覚フィードバック
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                isCalculatingCommute = true
                Task {
                    await CommuteTimeService.shared.calculateForListing(listing, modelContext: modelContext)
                    saveContext()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isCalculatingCommute = false
                    }
                    // 完了時の触覚フィードバック
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(
                        listing.parsedCommuteInfo.hasFallbackEstimate ? .warning : .success
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    if isCalculatingCommute {
                        ProgressView()
                            .controlSize(.small)
                        Text("経路を検索中...")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("通勤時間を計算する")
                    }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(isCalculatingCommute)

            if isCalculatingCommute {
                Text("※ Apple Maps の公共交通機関経路を検索しています（数十秒かかる場合があります）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
        .animation(.easeInOut(duration: 0.2), value: isCalculatingCommute)
    }

    // MARK: - ハザード情報セクション

    @ViewBuilder
    private var hazardSection: some View {
        let hazard = listing.parsedHazardData
        let labels = hazard.allLabels  // 全ランク表示（低リスクも含む）

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
                        ForEach(Array(gsiItems.enumerated()), id: \.element.label) { _, item in
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

                    ForEach(Array(tokyoItems.enumerated()), id: \.element.label) { _, item in
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .font(.body)
                                .foregroundStyle(hazardIconColor(item.severity))
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

            // 総合危険度の見方ガイド
            hazardGuide
        }
        .padding(14)
        .tintedGlassBackground(tint: .orange, tintOpacity: 0.03, borderOpacity: 0.08)
    }

    /// ハザード解説ガイド — 各ランク・各ハザード項目の実際の影響度を説明
    @ViewBuilder
    private var hazardGuide: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("建物倒壊危険度と火災危険度を総合的に評価した東京都の公式指標です。地震発生時の相対的な危険性を5段階で示します。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    hazardRankRow(rank: 1, color: DesignSystem.positiveColor, text: "危険性が低い — 特段の心配は不要")
                    hazardRankRow(rank: 2, color: .yellow, text: "やや注意 — 平均的なリスク。一般的な備えで十分")
                    hazardRankRow(rank: 3, color: .orange, text: "注意が必要 — 耐震性・周辺環境を要確認")
                    hazardRankRow(rank: 4, color: DesignSystem.negativeColor, text: "危険 — 木造密集地・狭い道路が多い地域。保険の検討を推奨")
                    hazardRankRow(rank: 5, color: DesignSystem.negativeColor, text: "非常に危険 — 最優先で防災対策が必要な地域")
                }

                Divider()

                Text("ハザードマップ各項目の影響")
                    .font(.caption.weight(.semibold))

                VStack(alignment: .leading, spacing: 4) {
                    hazardItemRow(icon: "drop.fill", text: "洪水浸水 — 河川氾濫時の浸水想定区域。高層階なら直接被害は限定的だが、1階・地下駐車場に注意")
                    hazardItemRow(icon: "water.waves", text: "高潮浸水 — 台風等による高潮の浸水想定区域。湾岸エリアで該当が多い")
                    hazardItemRow(icon: "waveform.path", text: "液状化 — 地震時に地盤が液状化するリスク。杭基礎のマンションなら建物自体の倒壊リスクは低いが、周辺インフラに影響")
                    hazardItemRow(icon: "mountain.2.fill", text: "土砂災害 — 崖崩れ・土石流の警戒区域。該当する場合は重大リスク")
                    hazardItemRow(icon: "tsunami", text: "津波浸水 — 津波による浸水想定区域。高層階への避難が可能か要確認")
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "book.fill")
                    .font(.caption2)
                Text("総合危険度の見方")
                    .font(.caption.weight(.semibold))
                Text("— 東京都都市整備局")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.orange)
        }
    }

    private func hazardRankRow(rank: Int, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("ランク\(rank)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(width: 48)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hazardItemRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hazardIconColor(_ severity: Listing.HazardSeverity) -> Color {
        switch severity {
        case .danger: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
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
        case 1: return DesignSystem.positiveColor
        case 2: return .yellow
        case 3: return .orange
        case 4, 5: return DesignSystem.negativeColor
        default: return .gray
        }
    }

    // MARK: - 住まいサーフィン未取得通知

    @ViewBuilder
    private var sumaiSurfinUnavailableNotice: some View {
        let status = listing.ssLookupStatus

        VStack(alignment: .leading, spacing: 8) {
            Label("住まいサーフィン評価", systemImage: "chart.bar.xaxis")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)

            if status == "not_found" {
                // 住まいサーフィンで検索したが、該当物件が見つからなかった
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("住まいサーフィンに該当物件が見つかりませんでした")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("物件名の表記揺れ（棟名・広告文・英字/カタカナ違い等）により自動マッチングできなかった可能性があります。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if status == "no_data" {
                // 住まいサーフィンにページはあるが、評価データがなかった
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("住まいサーフィンに掲載されていますが、評価データがありません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("物件ページは存在しますが、沖式時価・儲かる確率等の評価データがまだ公開されていません。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                // nil = 未検索（パイプライン未実行 or 古いデータ）
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("住まいサーフィン情報は未取得です")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("データ取得パイプラインが未実行、または古いデータのため情報がありません。次回のデータ更新で取得される場合があります。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .tintedGlassBackground(tint: Color.secondary, tintOpacity: 0.03, borderOpacity: 0.08)
    }

    // MARK: - 住まいサーフィン評価セクション

    @ViewBuilder
    private var sumaiSurfinSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // セクションヘッダー
            Label("住まいサーフィン評価", systemImage: "chart.bar.xaxis")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)

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

            // 販売価格割安判定（住まいサーフィン評価の一部として表示）
            if listing.hasPriceJudgments {
                Divider()
                priceJudgmentsSection
            }
        }
        .padding(14)
        .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
    }

    // MARK: - 中古マンション: 沖式中古時価 + 値上がり率 + レーダーチャート

    @ViewBuilder
    private var chukoSumaiSection: some View {
        // 沖式中古時価（実面積換算 / 70㎡換算）と値上がり率
        HStack(alignment: .top, spacing: 4) {
            if let price70 = listing.ssOkiPrice70m2 {
                VStack(alignment: .leading, spacing: 2) {
                    // 実面積換算がある場合はそれをメイン表示
                    if let priceArea = listing.ssOkiPriceForArea, let area = listing.areaM2 {
                        Text("沖式中古時価（\(String(format: "%.1f", area))㎡換算）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(priceArea.formatted())
                                .font(.system(.title, design: .rounded).weight(.heavy))
                                .foregroundStyle(Color.accentColor)
                            Text("万円")
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor.opacity(0.6))
                        }
                        Text("70㎡換算: \(price70.formatted())万円")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        // 面積情報がない場合は従来通り 70㎡換算を表示
                        Text("沖式中古時価（70㎡換算）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(price70.formatted())
                                .font(.system(.title, design: .rounded).weight(.heavy))
                                .foregroundStyle(Color.accentColor)
                            Text("万円")
                                .font(.subheadline)
                                .foregroundStyle(Color.accentColor.opacity(0.6))
                        }
                    }
                    if let judgment = listing.computedPriceJudgment {
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
                        Text({
                            let formatted = rate.truncatingRemainder(dividingBy: 1) == 0
                                ? String(format: "%.0f", rate)
                                : String(format: "%.1f", rate)
                            return rate >= 0 ? "+\(formatted)" : formatted
                        }())
                            .font(.system(.title2, design: .rounded).weight(.heavy))
                            .foregroundStyle(rate >= 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor)
                        Text("%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(rate >= 0 ? DesignSystem.positiveColor.opacity(0.6) : DesignSystem.negativeColor.opacity(0.6))
                    }
                }
            } else if listing.hasSumaiSurfinData {
                // SS データはあるが値上がり率が未取得の場合、項目だけ表示
                VStack(alignment: .trailing, spacing: 2) {
                    Text("中古値上がり率")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("—")
                        .font(.system(.title2, design: .rounded).weight(.heavy))
                        .foregroundStyle(.tertiary)
                }
            }
        }

        // レーダーチャート（偏差値ベース: 本物件 vs 行政区平均）
        if let radar = listing.parsedRadarData {
            RadarChartView(data: radar)
                .frame(maxWidth: 260)
                .frame(maxWidth: .infinity) // 中央寄せ

            // 平均偏差値ヘッダー
            HStack(spacing: 6) {
                Text("平均偏差値")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f", radar.average))
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .foregroundStyle(deviationColor(radar.average))
                Spacer()
            }

            // 各軸の偏差値テーブル
            VStack(spacing: 0) {
                ForEach(0..<Listing.RadarData.labelsSingleLine.count, id: \.self) { index in
                    let label = Listing.RadarData.labelsSingleLine[index]
                    let value = radar.values[index]
                    HStack {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f", value))
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(deviationColor(value))
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.gray.opacity(0.04))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.1), lineWidth: 0.5)
            )
        }
    }

    /// 偏差値の色分け（50を基準にグラデーション）
    private func deviationColor(_ value: Double) -> Color {
        if value >= 60 { return .blue }
        if value >= 55 { return .cyan }
        if value >= 50 { return .teal }
        if value >= 45 { return .orange }
        return .gray
    }

    // MARK: - 新築マンション: 儲かる確率

    @ViewBuilder
    private var shinchikuSumaiSection: some View {
        // ── 儲かる確率 + m²割安額 ──
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
                    if let discount = listing.ssM2Discount {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("m²割安額")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 1) {
                                Text(discount >= 0 ? "+\(discount)" : "\(discount)")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundStyle(discount <= 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor)
                                Text("万円/m²")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let judgment = listing.computedPriceJudgment {
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
        } else if let discount = listing.ssM2Discount {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("m²割安額")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(discount >= 0 ? "+\(discount)" : "\(discount)")
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(discount <= 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor)
                        Text("万円/m²")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let judgment = listing.computedPriceJudgment {
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

        // ── 10年後予測詳細 ──
        if listing.hasForecastDetail {
            forecastDetailSection
        }
    }

    /// 10年後予測詳細セクション（新築のみ）
    @ViewBuilder
    private var forecastDetailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("10年後予測詳細")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                Spacer()
                // シミュレーションセクションで購入判定を表示する場合は重複を避ける
                if !listing.hasSimulationData, let judgment = listing.ssPurchaseJudgment {
                    Text(judgment)
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            judgment.contains("値上がり") || judgment.contains("期待")
                                ? DesignSystem.positiveColor.opacity(0.12)
                                : Color.secondary.opacity(0.12)
                        )
                        .foregroundStyle(
                            judgment.contains("値上がり") || judgment.contains("期待")
                                ? DesignSystem.positiveColor
                                : .primary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            // 詳細行
            VStack(spacing: 6) {
                if let price = listing.ssOkiPrice70m2 {
                    forecastRow(label: "沖式新築時価", value: "\(price.formatted())万円", subLabel: "(70㎡)")
                }
                if let m2Price = listing.ssNewM2Price {
                    forecastRow(label: "新築時m²単価", value: "\(m2Price)万円/㎡")
                }
                if let forecastM2 = listing.ssForecastM2Price {
                    forecastRow(label: "10年後予測m²", value: "\(forecastM2)万円/㎡")
                }
                if let changeRate = listing.ssForecastChangeRate {
                    let formatted = changeRate.truncatingRemainder(dividingBy: 1) == 0
                        ? String(format: "%.0f", changeRate)
                        : String(format: "%.1f", changeRate)
                    let sign = changeRate >= 0 ? "+" : ""
                    forecastRow(
                        label: "予測変動率",
                        value: "\(sign)\(formatted)%",
                        valueColor: changeRate >= 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor
                    )
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func forecastRow(label: String, value: String, subLabel: String? = nil, valueColor: Color = .primary) -> some View {
        HStack {
            HStack(spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let sub = subLabel {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(valueColor)
        }
    }

    // MARK: - 周辺の中古マンション相場

    @ViewBuilder
    private var surroundingPropertiesSection: some View {
        let properties = listing.parsedSurroundingProperties

        VStack(alignment: .leading, spacing: 0) {
            // ヘッダーボタン（タップで展開/折りたたみ）
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSurroundingExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("周辺の中古マンション相場")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("\(properties.count)件")
                            .font(.caption2)
                        Image(systemName: isSurroundingExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // 展開部分
            if isSurroundingExpanded {
                VStack(spacing: 0) {
                    ForEach(properties) { prop in
                        HStack {
                            // 物件名
                            if let url = prop.url, let propURL = URL(string: url) {
                                Button {
                                    safariURL = propURL
                                } label: {
                                    Text(prop.name)
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(prop.name)
                                    .font(.caption)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            // 値上がり率（未取得時は "—" を表示）
                            if let rate = prop.appreciationRate {
                                Text(String(format: "%.1f%%", rate))
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                    .foregroundStyle(rate >= 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor)
                                    .frame(width: 50, alignment: .trailing)
                            } else {
                                Text("—")
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 50, alignment: .trailing)
                            }

                            // 沖式中古時価 70m²
                            if let price = prop.okiPrice70m2 {
                                Text("\(price.formatted())万")
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)

                        if prop.id != properties.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(8)
                .background(Color(.systemGray6).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - 販売価格割安判定（住まいサーフィン評価セクション内に表示）

    @ViewBuilder
    private var priceJudgmentsSection: some View {
        let units = listing.parsedPriceJudgments

        VStack(alignment: .leading, spacing: 0) {
            // ヘッダーボタン
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isPriceJudgmentsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("販売価格 割安判定")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        let cheapCount = units.filter { $0.judgment == "割安" || $0.judgment == "やや割安" }.count
                        if cheapCount > 0 {
                            Text("\(cheapCount)/\(units.count)戸割安")
                                .font(.caption2)
                                .foregroundStyle(DesignSystem.positiveColor)
                        } else {
                            Text("\(units.count)戸")
                                .font(.caption2)
                        }
                        Image(systemName: isPriceJudgmentsExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // 展開部分
            if isPriceJudgmentsExpanded {
                VStack(spacing: 0) {
                    ForEach(units) { unit in
                        VStack(alignment: .leading, spacing: 4) {
                            // 1行目: 住戸情報 + 判定
                            HStack {
                                if let unitLabel = unit.unit {
                                    Text(unitLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let layout = unit.layout {
                                    Text(layout)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let area = unit.areaM2 {
                                    Text(String(format: "%.1fm²", area))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let judgment = unit.judgment {
                                    Text(judgment)
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(priceJudgmentColor(judgment).opacity(0.15))
                                        .foregroundStyle(priceJudgmentColor(judgment))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }

                            // 2行目: 価格比較
                            HStack(spacing: 12) {
                                if let price = unit.priceMan {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("販売価格")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                        Text("\(price.formatted())万")
                                            .font(.system(.caption, design: .rounded).weight(.semibold))
                                    }
                                }
                                if let okiPrice = unit.okiPriceMan {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("沖式時価")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                        Text("\(okiPrice.formatted())万")
                                            .font(.system(.caption, design: .rounded).weight(.semibold))
                                    }
                                }
                                if let diff = unit.differenceMan {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("差額")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                        Text("\(diff >= 0 ? "+" : "")\(diff.formatted())万")
                                            .font(.system(.caption, design: .rounded).weight(.bold))
                                            .foregroundStyle(diff <= 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)

                        if unit.id != units.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(8)
                .background(Color(.systemGray6).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 割安判定のカラーマッピング
    private func priceJudgmentColor(_ judgment: String) -> Color {
        switch judgment {
        case "割安", "やや割安":
            return DesignSystem.positiveColor
        case "割高", "やや割高":
            return DesignSystem.negativeColor
        case "適正", "適正価格":
            return Color.orange
        default:
            return Color.secondary
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
        if pct >= 70 { return DesignSystem.positiveColor }
        if pct >= 40 { return .orange }
        return DesignSystem.negativeColor
    }

    private func judgmentColor(_ judgment: String) -> Color {
        switch judgment {
        case "割安", "やや割安": return DesignSystem.positiveColor
        case "適正", "適正価格": return .secondary
        case "割高", "やや割高": return DesignSystem.negativeColor
        default: return .secondary
        }
    }

    private func saveContext() {
        SaveErrorHandler.shared.save(modelContext, source: "ListingDetail")
    }
}

/// ハザードチップ
private struct HazardChip: View {
    let icon: String
    let label: String
    let severity: Listing.HazardSeverity

    private var chipColor: Color {
        switch severity {
        case .danger: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            chipColor.opacity(0.12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 詳細画面の1行（左ラベル / 右値）。HTML 準拠の1列リストレイアウト。
private struct DetailRow: View {
    let title: String
    let value: String
    var accentValue: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(ListingObjectStyle.detailLabel)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(ListingObjectStyle.detailValue)
                .foregroundStyle(accentValue ? Color.accentColor : .primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

/// 間取り図フルスクリーン表示（ピンチズーム対応）
private struct FloorPlanFullScreenView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black.ignoresSafeArea()

                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .scaleEffect(scale)
                                .offset(offset)
                                .gesture(
                                    MagnifyGesture()
                                        .onChanged { value in
                                            scale = lastScale * value.magnification
                                        }
                                        .onEnded { value in
                                            lastScale = max(1.0, scale)
                                            scale = lastScale
                                            if scale == 1.0 {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    offset = .zero
                                                    lastOffset = .zero
                                                }
                                            }
                                        }
                                        .simultaneously(with:
                                            DragGesture()
                                                .onChanged { value in
                                                    if scale > 1.0 {
                                                        offset = CGSize(
                                                            width: lastOffset.width + value.translation.width,
                                                            height: lastOffset.height + value.translation.height
                                                        )
                                                    }
                                                }
                                                .onEnded { _ in
                                                    lastOffset = offset
                                                }
                                        )
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        if scale > 1.0 {
                                            scale = 1.0
                                            lastScale = 1.0
                                            offset = .zero
                                            lastOffset = .zero
                                        } else {
                                            scale = 2.5
                                            lastScale = 2.5
                                        }
                                    }
                                }
                        case .failure:
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.largeTitle)
                                Text("画像を読み込めません")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white.opacity(0.6))
                        case .empty:
                            ProgressView()
                                .tint(.white)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white.opacity(0.8), .white.opacity(0.2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

/// 通勤カードのボタンスタイル: 押下時にスケール + 透明度で視覚フィードバック
private struct CommuteCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview("基本") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    do {
        let container = try ModelContainer(for: Listing.self, configurations: config)
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
    } catch {
        return ContentUnavailableView {
            Label("プレビューエラー", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        }
    }
}

#Preview("間取り図あり（1枚）") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    do {
        let container = try ModelContainer(for: Listing.self, configurations: config)
        // サンプル間取り図 URL（パブリックドメインのフロアプラン画像）
        let floorPlanURLs = ["https://upload.wikimedia.org/wikipedia/commons/thumb/4/49/Bergansius_plan.jpg/800px-Bergansius_plan.jpg"]
        let floorPlanJSON = String(data: try JSONSerialization.data(withJSONObject: floorPlanURLs), encoding: .utf8)
        let sample = Listing(
            source: "suumo",
            url: "https://example.com/2",
            name: "パークタワー渋谷",
            priceMan: 12500,
            address: "東京都渋谷区桜丘町1-1",
            stationLine: "JR山手線「渋谷」徒歩3分／東京メトロ銀座線「渋谷」徒歩5分",
            walkMin: 3,
            areaM2: 72.5,
            layout: "3LDK",
            builtYear: 2018,
            totalUnits: 250,
            floorPosition: 15,
            floorTotal: 30,
            ownership: "所有権",
            managementFee: 15000,
            repairReserveFund: 12000,
            floorPlanImagesJSON: floorPlanJSON
        )
        container.mainContext.insert(sample)
        return ListingDetailView(listing: sample)
            .modelContainer(container)
    } catch {
        return ContentUnavailableView {
            Label("プレビューエラー", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        }
    }
}

#Preview("間取り図あり（複数枚）") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    do {
        let container = try ModelContainer(for: Listing.self, configurations: config)
        let floorPlanURLs = [
            "https://upload.wikimedia.org/wikipedia/commons/thumb/4/49/Bergansius_plan.jpg/800px-Bergansius_plan.jpg",
            "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1e/Camellia_Hill_Floor_Plan.jpg/800px-Camellia_Hill_Floor_Plan.jpg",
            "https://upload.wikimedia.org/wikipedia/commons/thumb/9/97/Gropius_house_-_first_floor_plan.png/800px-Gropius_house_-_first_floor_plan.png"
        ]
        let floorPlanJSON = String(data: try JSONSerialization.data(withJSONObject: floorPlanURLs), encoding: .utf8)
        let sample = Listing(
            source: "homes",
            url: "https://example.com/3",
            name: "ザ・パークハウス表参道",
            priceMan: 18900,
            address: "東京都港区南青山3-10-5",
            stationLine: "東京メトロ銀座線「表参道」徒歩2分",
            walkMin: 2,
            areaM2: 85.3,
            layout: "3LDK",
            builtYear: 2020,
            totalUnits: 80,
            floorPosition: 8,
            floorTotal: 15,
            ownership: "所有権",
            managementFee: 25000,
            repairReserveFund: 18000,
            floorPlanImagesJSON: floorPlanJSON
        )
        container.mainContext.insert(sample)
        return ListingDetailView(listing: sample)
            .modelContainer(container)
    } catch {
        return ContentUnavailableView {
            Label("プレビューエラー", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        }
    }
}
