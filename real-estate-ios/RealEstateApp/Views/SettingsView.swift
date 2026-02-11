//
//  SettingsView.swift
//  RealEstateApp
//
//  HIG: Form による設定画面。セクション・フッターで意図を明確に。
//  デフォルト URL が組み込まれているため、初回セットアップ不要。
//  詳細設定（カスタム URL）は DisclosureGroup で折りたたみ。
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ListingStore.self) private var store
    @Environment(AuthService.self) private var authService
    @State private var chukoURLInput: String = ""
    @State private var shinchikuURLInput: String = ""
    @State private var showSaveConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showAdvancedURL = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - データ更新
                Section {
                    Button {
                        Task {
                            await store.refresh(modelContext: modelContext)
                        }
                    } label: {
                        HStack {
                            Label("今すぐ更新", systemImage: "arrow.clockwise")
                            Spacer()
                            if store.isRefreshing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.isRefreshing)

                    Button {
                        store.clearETags()
                        Task {
                            await store.refresh(modelContext: modelContext)
                        }
                    } label: {
                        Label("フルリフレッシュ（キャッシュクリア）", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.isRefreshing)
                } header: {
                    Text("データ更新")
                } footer: {
                    Text("通常の更新は差分チェック（ETag）で未変更ならスキップします。フルリフレッシュはキャッシュをクリアして全件再取得します。")
                }

                // MARK: - ステータス
                Section {
                    if let at = store.lastFetchedAt {
                        HStack {
                            Text("最終確認")
                            Spacer()
                            Text(at, style: .date)
                            Text(at, style: .time)
                        }
                    }
                    HStack {
                        Text("データソース")
                        Spacer()
                        Text(store.isUsingCustomURL ? "カスタム URL" : "デフォルト")
                            .foregroundStyle(.secondary)
                    }
                    if !store.lastRefreshHadChanges, store.lastFetchedAt != nil {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("最新のデータです（変更なし）")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("ステータス")
                }

                if let err = store.lastError {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(ListingObjectStyle.caption)
                    } header: {
                        Text("エラー")
                    }
                }

                // MARK: - 詳細設定（カスタム URL）
                Section {
                    DisclosureGroup("カスタム URL 設定", isExpanded: $showAdvancedURL) {
                        TextField("中古マンション JSON URL", text: $chukoURLInput)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(ListingObjectStyle.caption)
                        TextField("新築マンション JSON URL", text: $shinchikuURLInput)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .font(ListingObjectStyle.caption)

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
                    }
                } header: {
                    Text("詳細設定")
                } footer: {
                    Text("通常はデフォルト URL（GitHub）から自動取得します。独自のサーバーからデータを配信する場合のみカスタム URL を設定してください。")
                }

                // MARK: - 参考リンク
                Section {
                    Link("SUUMO 中古マンション", destination: URL(string: "https://suumo.jp/ms/chuko/")!)
                    Link("SUUMO 新築マンション", destination: URL(string: "https://suumo.jp/ms/shinchiku/")!)
                    Link("HOME'S 中古マンション", destination: URL(string: "https://www.homes.co.jp/mansion/chuko/")!)
                    Link("HOME'S 新築マンション", destination: URL(string: "https://www.homes.co.jp/mansion/shinchiku/")!)
                } header: {
                    Text("参考リンク")
                }

                // MARK: - アカウント
                Section {
                    if let name = authService.userDisplayName {
                        HStack {
                            Text("アカウント")
                            Spacer()
                            Text(name)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let email = authService.userEmail {
                        HStack {
                            Text("メール")
                            Spacer()
                            Text(email)
                                .foregroundStyle(.secondary)
                                .font(ListingObjectStyle.caption)
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
            .navigationTitle("設定")
            .onAppear {
                chukoURLInput = store.listURL
                shinchikuURLInput = store.shinchikuListURL
                // カスタム URL が設定済みなら展開しておく
                showAdvancedURL = store.isUsingCustomURL
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
}

#Preview {
    SettingsView()
        .environment(ListingStore.shared)
        .environment(AuthService.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
