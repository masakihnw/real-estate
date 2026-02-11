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
    /// SFSafariViewController 表示用
    @State private var safariURL: URL?
    /// HIG: 破壊的操作の確認用（コメント削除）
    @State private var deletingCommentId: String?

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

                    // ① 物件名 ＋ いいね
                    HStack(alignment: .top, spacing: 12) {
                        Text(listing.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                        Button {
                            listing.isLiked.toggle()
                            saveContext()
                            FirebaseSyncService.shared.pushLikeState(for: listing)
                        } label: {
                            Image(systemName: listing.isLiked ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(listing.isLiked ? .red : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(listing.isLiked ? "いいねを解除" : "いいねする")
                    }
                    .accessibilityElement(children: .combine)

                    // ② 住所（Google Maps アイコンボタン）
                    if let addr = listing.address, !addr.isEmpty {
                        HStack(spacing: 8) {
                            Text(addr)
                                .font(ListingObjectStyle.subtitle)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button {
                                let query = listing.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? listing.name
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

                    Divider()

                    // ③ コメント（家族間共有）
                    commentSection

                    Divider()

                    // ④ 内見写真
                    PhotoSectionView(listing: listing)

                    Divider()

                    // ⑤ 物件情報（マージ: 旧「物件情報」+「アクセス・権利」を統合）
                    propertyInfoSection

                    // ⑤-b 通勤時間
                    if listing.hasCommuteInfo {
                        Divider()
                        commuteSection
                    } else if listing.hasCoordinate {
                        Divider()
                        commuteCalculateSection
                    }

                    Divider()

                    // ⑥ 住まいサーフィン評価
                    if listing.hasSumaiSurfinData {
                        sumaiSurfinSection
                    }

                    // 値上がり・含み益シミュレーション
                    if listing.hasSimulationData {
                        Divider()
                        SimulationSectionView(listing: listing)
                    }

                    // ⑦ ハザード情報
                    if listing.hasHazardRisk {
                        Divider()
                        hazardSection
                    }

                    Divider()

                    // ⑧ 外部サイトボタン or 掲載終了メッセージ
                    if listing.isDelisted {
                        delistedNotice
                    } else {
                        externalLinksSection
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            .onTapGesture {
                // コメント入力以外をタップでキーボードを閉じる
                isCommentFocused = false
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

    // MARK: - ③ 物件情報（最寄駅 + 属性グリッド）

    @ViewBuilder
    private var propertyInfoSection: some View {
        // 最寄駅（物件情報の先頭項目として表示）
        stationSection

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
    }

    @ViewBuilder
    private var stationSection: some View {
        let stations = listing.parsedStations
        if !stations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // メイン行：ラベル左、駅名+徒歩右（DetailItem と同じレイアウト）
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
    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
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

            // 注釈
            VStack(alignment: .leading, spacing: 2) {
                Text("※ Apple Maps の公共交通機関経路に基づく自動計算です")
                Text("※ 平日朝 8:00 出発での最適経路")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(14)
        .listingGlassBackground()
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
                Task {
                    await CommuteTimeService.shared.calculateForListing(listing, modelContext: modelContext)
                    saveContext()
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("通勤時間を計算する")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .listingGlassBackground()
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
        case 1: return DesignSystem.positiveColor
        case 2: return .yellow
        case 3: return .orange
        case 4, 5: return DesignSystem.negativeColor
        default: return .gray
        }
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
                            .foregroundStyle(rate >= 0 ? DesignSystem.positiveColor : DesignSystem.negativeColor)
                        Text("%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(rate >= 0 ? DesignSystem.positiveColor.opacity(0.6) : DesignSystem.negativeColor.opacity(0.6))
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
        if pct >= 70 { return DesignSystem.positiveColor }
        if pct >= 40 { return .orange }
        return DesignSystem.negativeColor
    }

    private func judgmentColor(_ judgment: String) -> Color {
        switch judgment {
        case "割安": return DesignSystem.positiveColor
        case "適正": return .secondary
        case "割高": return DesignSystem.negativeColor
        default: return .secondary
        }
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            print("[ListingDetail] modelContext.save() 失敗: \(error)")
        }
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

/// 通勤カードのボタンスタイル: 押下時にスケール + 透明度で視覚フィードバック
private struct CommuteCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
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
