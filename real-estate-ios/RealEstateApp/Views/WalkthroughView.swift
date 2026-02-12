//
//  WalkthroughView.swift
//  RealEstateApp
//
//  初回ログイン後に表示するウォークスルー / チュートリアル。
//  設定画面からいつでも再表示可能。
//  7 ページ構成で、アプリの全機能を紹介する。
//

import SwiftUI

// MARK: - UserDefaults Key

extension UserDefaults {
    private static let walkthroughCompletedKey = "realestate.walkthroughCompleted"

    /// ウォークスルーを完了済みかどうか
    var walkthroughCompleted: Bool {
        get { bool(forKey: Self.walkthroughCompletedKey) }
        set { set(newValue, forKey: Self.walkthroughCompletedKey) }
    }
}

// MARK: - Walkthrough Data Model

private struct WalkthroughPage: Identifiable {
    let id: Int
    let icon: String
    let iconColors: [Color]
    let title: String
    let subtitle: String
    let features: [WalkthroughFeature]
}

private struct WalkthroughFeature: Identifiable {
    let id = UUID()
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
}

// MARK: - Walkthrough Pages Data

private let walkthroughPages: [WalkthroughPage] = [
    // Page 1: Welcome
    WalkthroughPage(
        id: 0,
        icon: "building.2.fill",
        iconColors: [Color(red: 0.20, green: 0.50, blue: 0.95), Color(red: 0.40, green: 0.70, blue: 1.0)],
        title: "物件情報へようこそ",
        subtitle: "中古・新築マンションの検索から比較、\nお気に入り管理まで一つのアプリで。",
        features: [
            WalkthroughFeature(icon: "magnifyingglass", iconColor: .blue, title: "かんたん検索", description: "価格・間取り・エリアで絞り込み"),
            WalkthroughFeature(icon: "map.fill", iconColor: .green, title: "地図で探す", description: "ハザードマップも重ねて表示"),
            WalkthroughFeature(icon: "heart.fill", iconColor: .pink, title: "お気に入り管理", description: "気になる物件をまとめて比較"),
        ]
    ),
    // Page 2: Property List
    WalkthroughPage(
        id: 1,
        icon: "list.bullet.rectangle.fill",
        iconColors: [Color(red: 0.95, green: 0.55, blue: 0.20), Color(red: 1.0, green: 0.75, blue: 0.35)],
        title: "物件リスト",
        subtitle: "中古タブと新築タブで物件を一覧。\n豊富なフィルターとソートで効率的に探せます。",
        features: [
            WalkthroughFeature(icon: "slider.horizontal.3", iconColor: .orange, title: "詳細フィルター", description: "価格帯・間取り・区・駅徒歩・面積・所有権"),
            WalkthroughFeature(icon: "arrow.up.arrow.down", iconColor: .purple, title: "並び替え", description: "新着順・価格順・駅徒歩順・面積順"),
            WalkthroughFeature(icon: "sparkles", iconColor: .yellow, title: "新築タブ", description: "未定価格の物件も表示・フィルター対応"),
        ]
    ),
    // Page 3: Map
    WalkthroughPage(
        id: 2,
        icon: "map.fill",
        iconColors: [Color(red: 0.20, green: 0.75, blue: 0.45), Color(red: 0.40, green: 0.90, blue: 0.65)],
        title: "地図で探す",
        subtitle: "物件をマップ上で確認。\nハザード情報を重ねて安全性もチェック。",
        features: [
            WalkthroughFeature(icon: "mappin.and.ellipse", iconColor: .blue, title: "物件ピン", description: "中古=青、新築=緑、お気に入り=赤で表示"),
            WalkthroughFeature(icon: "exclamationmark.triangle.fill", iconColor: .orange, title: "ハザードマップ", description: "洪水・土砂・高潮・津波・液状化・揺れやすさ"),
            WalkthroughFeature(icon: "flame.fill", iconColor: .red, title: "東京都リスク", description: "建物倒壊・火災・総合危険度を重ねて表示"),
        ]
    ),
    // Page 4: Favorites & Comparison
    WalkthroughPage(
        id: 3,
        icon: "heart.rectangle.fill",
        iconColors: [Color(red: 0.95, green: 0.30, blue: 0.45), Color(red: 1.0, green: 0.55, blue: 0.65)],
        title: "お気に入り＆比較",
        subtitle: "気になる物件をお気に入りに追加して、\n最大4件を並べて比較できます。",
        features: [
            WalkthroughFeature(icon: "heart.fill", iconColor: .pink, title: "スワイプでお気に入り", description: "リスト上で左スワイプして即座に追加"),
            WalkthroughFeature(icon: "rectangle.split.2x1.fill", iconColor: .indigo, title: "比較モード", description: "2〜4件を横並びで価格・面積・駅徒歩を比較"),
            WalkthroughFeature(icon: "square.and.arrow.up", iconColor: .teal, title: "CSV エクスポート", description: "お気に入りをCSVで書き出し可能"),
        ]
    ),
    // Page 5: Detail
    WalkthroughPage(
        id: 4,
        icon: "doc.text.magnifyingglass",
        iconColors: [Color(red: 0.55, green: 0.30, blue: 0.85), Color(red: 0.75, green: 0.50, blue: 1.0)],
        title: "物件の詳細情報",
        subtitle: "物件タップで詳細画面へ。\n通勤時間や住まいサーフィン情報も確認。",
        features: [
            WalkthroughFeature(icon: "bubble.left.and.bubble.right.fill", iconColor: .blue, title: "家族でコメント共有", description: "家族間でコメントを残し、意見を共有"),
            WalkthroughFeature(icon: "camera.fill", iconColor: .gray, title: "写真を追加", description: "カメラやアルバムから内覧写真を保存"),
            WalkthroughFeature(icon: "car.fill", iconColor: DesignSystem.commutePGColor, title: "通勤時間", description: "Playground・M3Career への所要時間を自動計算"),
            WalkthroughFeature(icon: "chart.pie.fill", iconColor: .purple, title: "住まいサーフィン", description: "レーダーチャート・値上がり率・含み益表示"),
        ]
    ),
    // Page 6: Notifications & Smart Features
    WalkthroughPage(
        id: 5,
        icon: "bell.badge.fill",
        iconColors: [Color(red: 0.95, green: 0.65, blue: 0.15), Color(red: 1.0, green: 0.80, blue: 0.30)],
        title: "通知＆便利機能",
        subtitle: "新着物件やコメントの通知で\n見逃しを防ぎます。",
        features: [
            WalkthroughFeature(icon: "bell.fill", iconColor: .orange, title: "新着通知", description: "1日最大6回、好きな時刻に通知を受信"),
            WalkthroughFeature(icon: "bubble.left.fill", iconColor: .blue, title: "コメント通知", description: "家族がコメントしたら即時通知"),
            WalkthroughFeature(icon: "arrow.clockwise", iconColor: .green, title: "自動更新", description: "バックグラウンドで物件情報を最新に保持"),
            WalkthroughFeature(icon: "wifi.slash", iconColor: .gray, title: "オフライン対応", description: "通信がなくても保存済みデータを閲覧可能"),
        ]
    ),
    // Page 7: Get Started
    WalkthroughPage(
        id: 6,
        icon: "checkmark.seal.fill",
        iconColors: [Color(red: 0.20, green: 0.50, blue: 0.95), Color(red: 0.40, green: 0.70, blue: 1.0)],
        title: "準備完了！",
        subtitle: "さっそく物件を探してみましょう。\n設定画面からいつでもこのガイドを\n見直すことができます。",
        features: [
            WalkthroughFeature(icon: "hand.tap.fill", iconColor: .blue, title: "検索してみよう", description: "中古・新築タブで気になるエリアをフィルター"),
            WalkthroughFeature(icon: "star.fill", iconColor: .yellow, title: "お気に入りに追加", description: "気になる物件をスワイプして保存"),
            WalkthroughFeature(icon: "gearshape.fill", iconColor: .gray, title: "通知を設定", description: "設定タブで通知頻度と時刻をカスタマイズ"),
        ]
    ),
]

// MARK: - WalkthroughView

struct WalkthroughView: View {
    /// 閉じるアクション
    var onDismiss: () -> Void

    @State private var currentPage = 0
    @State private var animateContent = false

    private let totalPages = walkthroughPages.count

    var body: some View {
        ZStack {
            // 背景グラデーション（ページに応じて色が変化）
            backgroundGradient
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: currentPage)

            VStack(spacing: 0) {
                // ヘッダー（スキップ / ページ数）
                headerBar

                // ページコンテンツ
                TabView(selection: $currentPage) {
                    ForEach(walkthroughPages) { page in
                        pageContent(for: page)
                            .tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentPage)

                // フッター（ページインジケーター + ボタン）
                footerBar
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.2)) {
                animateContent = true
            }
        }
        .onChange(of: currentPage) { _, _ in
            animateContent = false
            withAnimation(.easeOut(duration: 0.4).delay(0.1)) {
                animateContent = true
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        let page = walkthroughPages[currentPage]
        let baseColor = page.iconColors[0]
        return LinearGradient(
            stops: [
                .init(color: baseColor.opacity(0.08), location: 0.0),
                .init(color: baseColor.opacity(0.04), location: 0.3),
                .init(color: Color(red: 0.97, green: 0.97, blue: 0.99), location: 0.6),
                .init(color: Color(red: 0.98, green: 0.98, blue: 1.0), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            // ページ番号
            Text("\(currentPage + 1) / \(totalPages)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            Spacer()

            // スキップ（最終ページ以外で表示）
            if currentPage < totalPages - 1 {
                Button {
                    complete()
                } label: {
                    Text("スキップ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 20)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Page Content

    @ViewBuilder
    private func pageContent(for page: WalkthroughPage) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                // アイコン
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: page.iconColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 96, height: 96)
                        .shadow(color: page.iconColors[0].opacity(0.35), radius: 16, x: 0, y: 8)

                    Image(systemName: page.icon)
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                        .symbolRenderingMode(.hierarchical)
                }
                .padding(.top, 24)
                .scaleEffect(animateContent ? 1.0 : 0.7)
                .opacity(animateContent ? 1.0 : 0.0)

                // タイトル + サブタイトル
                VStack(spacing: 12) {
                    Text(page.title)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)

                    Text(page.subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 24)
                .offset(y: animateContent ? 0 : 12)
                .opacity(animateContent ? 1.0 : 0.0)

                // 機能カード
                VStack(spacing: 12) {
                    ForEach(Array(page.features.enumerated()), id: \.element.id) { index, feature in
                        featureCard(feature: feature, index: index)
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 80)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func featureCard(feature: WalkthroughFeature, index: Int) -> some View {
        HStack(spacing: 14) {
            // アイコン
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(feature.iconColor.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: feature.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(feature.iconColor)
            }

            // テキスト
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.subheadline.weight(.semibold))

                Text(feature.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 2)
        )
        .offset(y: animateContent ? 0 : 20)
        .opacity(animateContent ? 1.0 : 0.0)
        .animation(
            .easeOut(duration: 0.4).delay(Double(index) * 0.08 + 0.15),
            value: animateContent
        )
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(spacing: 20) {
            // ページインジケーター
            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Capsule()
                        .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == currentPage ? 24 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.3), value: currentPage)
                }
            }

            // ナビゲーションボタン
            HStack(spacing: 12) {
                // 戻るボタン（最初のページ以外）
                if currentPage > 0 {
                    Button {
                        withAnimation { currentPage -= 1 }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.caption.weight(.semibold))
                            Text("戻る")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(height: 50)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.systemGray6))
                        )
                    }
                }

                // 次へ / はじめる ボタン
                Button {
                    if currentPage < totalPages - 1 {
                        withAnimation { currentPage += 1 }
                    } else {
                        complete()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(currentPage < totalPages - 1 ? "次へ" : "はじめる")
                            .font(.subheadline.weight(.semibold))
                        if currentPage < totalPages - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(height: 50)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: walkthroughPages[currentPage].iconColors,
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .shadow(color: walkthroughPages[currentPage].iconColors[0].opacity(0.35),
                                    radius: 8, x: 0, y: 4)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .padding(.top, 8)
        .background(
            Color(red: 0.98, green: 0.98, blue: 1.0)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Actions

    private func complete() {
        UserDefaults.standard.walkthroughCompleted = true
        onDismiss()
    }
}

// MARK: - Preview

#Preview("Walkthrough") {
    WalkthroughView {
        print("Dismissed")
    }
}
