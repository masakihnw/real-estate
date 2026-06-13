//
//  SettingsView.swift
//  RealEstateApp
//
//  HIG: Form による設定画面。
//  通知 / データ / 詳細設定 / アカウント / このアプリについて の5セクション構成。
//

import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ListingStore.self) private var store
    @Environment(AuthService.self) private var authService

    // データ件数用クエリ
    @Query(filter: #Predicate<Listing> { $0.propertyType == "chuko" })
    private var chukoListings: [Listing]

    @State private var showSignOutConfirmation = false
    @State private var showFullRefreshConfirmation = false
    @State private var showScrapingLog = false
    @State private var showWalkthrough = false
    @State private var showTransactions = false

    // 開発者モード（バージョン行7回タップで解錠、UserDefaults 永続）
    @AppStorage("developerModeEnabled") private var developerModeEnabled = false
    @State private var devUnlock = DeveloperModeUnlock()

    // カスタム URL
    @State private var chukoURLInput: String = ""
    @State private var showAdvancedURL = false
    @State private var showSaveConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showCustomURLInfo = false

    // 通知
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    private var notifService: NotificationScheduleService { NotificationScheduleService.shared }

    // バージョン
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 通知
                notificationSection

                // MARK: - データ
                dataSection

                // MARK: - My指標
                customMetricSection

                // MARK: - 検討サポート
                supportSection

                // MARK: - アカウント
                accountSection

                // MARK: - このアプリについて
                aboutSection

                // MARK: - 開発者（7回タップで解錠）
                if developerModeEnabled {
                    developerSection
                }
            }
            .navigationTitle("設定")
            .onAppear {
                chukoURLInput = store.listURL
                showAdvancedURL = store.isUsingCustomURL
            }
            .sheet(isPresented: $showScrapingLog) {
                ScrapingLogView()
            }
            .sheet(isPresented: $showTransactions) {
                TransactionTabView()
            }
            .fullScreenCover(isPresented: $showWalkthrough) {
                WalkthroughView {
                    showWalkthrough = false
                }
            }
            .task {
                await refreshNotificationStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                // 設定アプリから戻った際に通知状態を再チェック
                Task { await refreshNotificationStatus() }
            }
            .alert("保存しました", isPresented: $showSaveConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("カスタム URL から取得するように変更しました。")
            }
            .alert("デフォルト URL に戻しますか？", isPresented: $showResetConfirmation) {
                Button("戻す", role: .destructive) {
                    store.listURL = ""
                    store.clearETags()
                    chukoURLInput = ""
                    showAdvancedURL = false
                }
                Button("キャンセル", role: .cancel) { }
            } message: {
                Text("GitHub のデフォルト URL から物件データを取得するようになります。")
            }
            .alert("ログアウトしますか？", isPresented: $showSignOutConfirmation) {
                Button("ログアウト", role: .destructive) {
                    authService.signOut()
                }
                Button("キャンセル", role: .cancel) { }
            } message: {
                Text("再度 Google アカウントでログインする必要があります。")
            }
        }
    }

    // MARK: - My指標（カスタム合成スコアの重み設定）

    @State private var customMetric = CustomMetric.load()

    @ViewBuilder
    private var customMetricSection: some View {
        Section {
            metricSlider("価格妥当性", value: $customMetric.weightPriceFairness)
            metricSlider("再販流動性", value: $customMetric.weightResaleLiquidity)
            metricSlider("総合スコア", value: $customMetric.weightListingScore)
            metricSlider("駅近（徒歩）", value: $customMetric.weightWalkConvenience)
            metricSlider("AI推奨度", value: $customMetric.weightAIRecommendation)
        } header: {
            Text("My指標の重み")
        } footer: {
            Text("一覧のソート「My指標（高い順）」で使う合成スコアの重み付けです。データが欠けている項目は自動的に除外して計算します。")
        }
        .onChange(of: customMetric) { _, newValue in
            newValue.save()
        }
    }

    private func metricSlider(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1, step: 0.05)
        }
    }

    // MARK: - アカウント

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let name = authService.userDisplayName {
                HStack {
                    Text("アカウント")
                    Spacer()
                    Text(name)
                }
            }
            if let email = authService.userEmail {
                HStack {
                    Text("メール")
                    Spacer()
                    Text(email)
                        .font(.caption)
                }
            }
            Button(role: .destructive) {
                showSignOutConfirmation = true
            } label: {
                Label("ログアウト", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text("アカウント")
        }
    }

    // MARK: - データ

    @ViewBuilder
    private var dataSection: some View {
        Section {
            NavigationLink {
                RecentlyViewedListView()
            } label: {
                Label("最近見た物件", systemImage: "clock.arrow.circlepath")
            }
            // 成約タブ廃止に伴う暫定導線（Phase 4 で地図レイヤー・詳細セクションに吸収予定）
            Button {
                showTransactions = true
            } label: {
                HStack {
                    Label("成約事例", systemImage: "chart.bar.doc.horizontal")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack {
                Text("中古マンション")
                Spacer()
                Text("\(chukoListings.count)件")
            }
            if !store.useSupabase {
                Label("データ取得元: カスタム（GitHub JSON）", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }


            if let at = store.lastFetchedAt {
                HStack {
                    Text("最終更新")
                    Spacer()
                    Text(at, style: .date)
                    Text(at, style: .time)
                }
            }
            if notifService.accumulatedNewCount > 0 {
                HStack {
                    Text("未通知の新着")
                    Spacer()
                    Text("\(notifService.accumulatedNewCount)件")
                }
            }
            Button {
                showFullRefreshConfirmation = true
            } label: {
                HStack {
                    Label("フルリフレッシュ", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if store.isRefreshing {
                        ProgressView()
                    }
                }
            }
            .disabled(store.isRefreshing)
        } header: {
            Text("データ")
        } footer: {
            Text("物件データは Supabase API から差分同期されます。\nフルリフレッシュはキャッシュをクリアして全件再取得します。")
        }
        .alert("フルリフレッシュしますか？", isPresented: $showFullRefreshConfirmation) {
            Button("実行", role: .destructive) {
                store.clearETags()
                Task {
                    await store.refresh(modelContext: modelContext)
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("キャッシュをクリアして全件再取得します。通信状況によっては数分かかる場合があります。実行中も他の画面は通常通り使用できます。")
        }
    }

    // MARK: - 通知

    @ViewBuilder
    private var notificationSection: some View {
        Section {
            // OS の通知許可状態
            switch notificationStatus {
            case .authorized, .provisional, .ephemeral:
                // 通知頻度（回数を自由に設定）
                Stepper(value: Binding(
                    get: { notifService.notificationCount },
                    set: { notifService.notificationCount = $0 }
                ), in: 0...6) {
                    HStack {
                        Text("通知頻度")
                        Spacer()
                        Text(notifService.notificationCount == 0 ? "OFF" : "1日\(notifService.notificationCount)回")
                    }
                }
                .accessibilityLabel("通知頻度")
                .accessibilityValue(notifService.notificationCount == 0 ? "オフ" : "1日\(notifService.notificationCount)回")

                // スケジュール時刻（0回以外で表示）
                if notifService.notificationCount > 0 {
                    ForEach(0..<notifService.scheduleTimes.count, id: \.self) { index in
                        let time = notifService.scheduleTimes[index]
                        DatePicker(
                            "\(index + 1)回目",
                            selection: Binding(
                                get: { time.date },
                                set: { newDate in
                                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                    notifService.updateTime(at: index, hour: comps.hour ?? 8, minute: comps.minute ?? 0)
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .accessibilityLabel("\(index + 1)回目の通知時刻")
                    }

                }

                // コメント通知
                Toggle(isOn: Binding(
                    get: { notifService.isCommentNotificationEnabled },
                    set: { notifService.isCommentNotificationEnabled = $0 }
                )) {
                    Text("コメント通知")
                }
                .accessibilityLabel("コメント通知")
                .accessibilityHint("他のユーザーのコメント時に通知を受け取ります")

            case .denied:
                Button {
                    openAppNotificationSettings()
                } label: {
                    HStack {
                        Text("通知を有効にする")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                    }
                }
            default:
                Button {
                    requestNotificationPermission()
                } label: {
                    Text("通知を許可する")
                }
            }
        } header: {
            Text("通知")
        } footer: {
            switch notificationStatus {
            case .denied:
                Text("通知が無効です。新着物件の通知を受け取るには、設定アプリで通知を有効にしてください。")
            case .authorized, .provisional, .ephemeral:
                if notifService.notificationCount > 0 {
                    Text("設定した時刻に、前回の通知からの新着件数をまとめて通知します。\nコメント通知は他のユーザーがコメントした時に即時通知します。")
                } else {
                    Text("コメント通知は他のユーザーがコメントした時に即時通知します。")
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: - 検討サポート（旧・詳細設定から昇格）

    @ViewBuilder
    private var supportSection: some View {
        Section {
            NavigationLink {
                PurchaseReadinessView()
            } label: {
                Label("買付準備", systemImage: "doc.text.magnifyingglass")
            }

            NavigationLink {
                CommuteDestinationSettingsView()
            } label: {
                Label("通勤先設定", systemImage: "building.2")
            }
        } header: {
            Text("検討サポート")
        }
    }

    // MARK: - 開発者（バージョン行7回タップで出現）

    @ViewBuilder
    private var developerSection: some View {
        Section {
            Button {
                showScrapingLog = true
            } label: {
                HStack {
                    Label("スクレイピングログ", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    if ScrapingLogService.shared.isLoading {
                        ProgressView()
                    }
                    if let log = ScrapingLogService.shared.latestLog {
                        Image(systemName: log.statusIcon)
                            .foregroundStyle(log.status == "success" ? .green : log.status == "error" ? .red : .secondary)
                            .font(.caption)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Toggle(isOn: Binding(
                get: { store.useSupabase },
                set: { store.useSupabase = $0 }
            )) {
                Label("Supabase API", systemImage: "server.rack")
            }

            if !store.useSupabase {
                DisclosureGroup(isExpanded: $showAdvancedURL) {
                    TextField("中古マンション JSON URL", text: $chukoURLInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .font(.caption)

                    Button {
                        store.listURL = chukoURLInput.trimmingCharacters(in: .whitespaces)
                        store.clearETags()
                        showSaveConfirmation = true
                    } label: {
                        Label("カスタム URL を保存", systemImage: "checkmark.circle")
                    }

                    if store.isUsingCustomURL {
                        Button(role: .destructive) {
                            showResetConfirmation = true
                        } label: {
                            Label("デフォルト URL に戻す", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    HStack {
                        Text("カスタム URL 設定")
                        Button {
                            showCustomURLInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                showDiagnostics.toggle()
            } label: {
                Label("診断情報", systemImage: "wrench.and.screwdriver")
            }
            if showDiagnostics {
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnosticsText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = diagnosticsText
                        diagnosticsCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            diagnosticsCopied = false
                        }
                    } label: {
                        Label(
                            diagnosticsCopied ? "コピーしました" : "クリップボードにコピー",
                            systemImage: diagnosticsCopied ? "checkmark" : "doc.on.doc"
                        )
                        .font(.caption)
                    }
                }
            }

            Button(role: .destructive) {
                developerModeEnabled = false
            } label: {
                Label("開発者モードを隠す", systemImage: "eye.slash")
            }
        } header: {
            Text("開発者")
        } footer: {
            Text("スクレイピング条件・ログ・データ取得元の切り替えなど、開発・検証用の機能です。")
        }
        .alert("カスタム URL 設定について", isPresented: $showCustomURLInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("物件データの取得元 URL を変更できます。\n\nデフォルトでは GitHub 上の JSON ファイルから物件データを自動取得しています。独自のサーバーやフォーク先のリポジトリから取得したい場合に JSON URL を指定できます。\n\n通常は変更不要です。")
        }
    }

    // MARK: - このアプリについて

    @State private var showDiagnostics = false
    @State private var diagnosticsCopied = false

    private var diagnosticsText: String {
        [
            "version: \(appVersion) (\(buildNumber))",
            "store: \(RealEstateAppApp.isInMemoryFallback ? "IN-MEMORY" : "disk")",
            "lastError: \(store.lastError ?? "none")",
            "lastFetched: \(store.lastFetchedAt?.formatted(.iso8601) ?? "nil")",
            RealEstateAppApp.containerDiagnostics,
        ].joined(separator: "\n")
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            Button {
                showWalkthrough = true
            } label: {
                HStack {
                    Label("使い方ガイド", systemImage: "questionmark.circle")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack {
                Text("バージョン")
                Spacer()
                Text("\(appVersion) (\(buildNumber))")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !developerModeEnabled else { return }
                if devUnlock.register() {
                    developerModeEnabled = true
                    HapticManager.success()
                }
            }
        } header: {
            Text("このアプリについて")
        }
    }

    // MARK: - Helpers

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            notificationStatus = settings.authorizationStatus
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { await refreshNotificationStatus() }
        }
    }

    private func openAppNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    SettingsView()
        .environment(ListingStore.shared)
        .environment(AuthService.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
