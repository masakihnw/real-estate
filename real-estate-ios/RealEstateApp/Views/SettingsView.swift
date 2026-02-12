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
    @Query(filter: #Predicate<Listing> { $0.propertyType == "shinchiku" })
    private var shinchikuListings: [Listing]

    @State private var showSignOutConfirmation = false
    @State private var showFullRefreshConfirmation = false
    @State private var showScrapingConfig = false
    @State private var showWalkthrough = false

    // カスタム URL
    @State private var chukoURLInput: String = ""
    @State private var shinchikuURLInput: String = ""
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

                // MARK: - 詳細設定
                advancedSection

                // MARK: - アカウント
                accountSection

                // MARK: - このアプリについて
                aboutSection
            }
            .navigationTitle("設定")
            .onAppear {
                chukoURLInput = store.listURL
                shinchikuURLInput = store.shinchikuListURL
                showAdvancedURL = store.isUsingCustomURL
            }
            .task {
                await ScrapingConfigService.shared.fetch()
            }
            .sheet(isPresented: $showScrapingConfig) {
                ScrapingConfigView(initialConfig: ScrapingConfigService.shared.config)
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
                    store.shinchikuListURL = ""
                    store.clearETags()
                    chukoURLInput = ""
                    shinchikuURLInput = ""
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
            HStack {
                Text("中古マンション")
                Spacer()
                Text("\(chukoListings.count)件")
            }
            HStack {
                Text("新築マンション")
                Spacer()
                Text("\(shinchikuListings.count)件")
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
            Text("物件データは自動で更新されます。\nフルリフレッシュはキャッシュをクリアして全件再取得します。")
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
                    ForEach(Array(notifService.scheduleTimes.enumerated()), id: \.offset) { index, time in
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

    // MARK: - 詳細設定

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            Button {
                showScrapingConfig = true
            } label: {
                HStack {
                    Label("スクレイピング条件", systemImage: "slider.horizontal.3")
                    Spacer()
                    if ScrapingConfigService.shared.isLoading {
                        ProgressView()
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            DisclosureGroup(isExpanded: $showAdvancedURL) {
                TextField("中古マンション JSON URL", text: $chukoURLInput)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .font(.caption)
                TextField("新築マンション JSON URL", text: $shinchikuURLInput)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .font(.caption)

                Button {
                    store.listURL = chukoURLInput.trimmingCharacters(in: .whitespaces)
                    store.shinchikuListURL = shinchikuURLInput.trimmingCharacters(in: .whitespaces)
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
        } header: {
            Text("詳細設定")
        } footer: {
            Text("スクレイピング条件で価格・専有面積などを編集できます。通常はデフォルト URL（GitHub）から自動取得します。")
        }
        .alert("カスタム URL 設定について", isPresented: $showCustomURLInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("物件データの取得元 URL を変更できます。\n\nデフォルトでは GitHub 上の JSON ファイルから物件データを自動取得しています。独自のサーバーやフォーク先のリポジトリから取得したい場合に、中古・新築それぞれの JSON URL を指定できます。\n\n通常は変更不要です。")
        }
    }

    // MARK: - このアプリについて

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
