//
//  SettingsView.swift
//  RealEstateApp
//
//  HIG: Form による設定画面。セクション・フッターで意図を明確に。
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("中古マンション JSON URL", text: $chukoURLInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    TextField("新築マンション JSON URL", text: $shinchikuURLInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text("データソース")
                } footer: {
                    Text("scraping-tool の results/latest.json（中古）と results/latest_shinchiku.json（新築）を配信しているURLを指定してください。")
                }

                Section {
                    Button {
                        store.listURL = chukoURLInput.trimmingCharacters(in: .whitespaces)
                        store.shinchikuListURL = shinchikuURLInput.trimmingCharacters(in: .whitespaces)
                        showSaveConfirmation = true
                    } label: {
                        Label("URLを保存", systemImage: "checkmark.circle")
                    }
                    .disabled(
                        chukoURLInput.trimmingCharacters(in: .whitespaces).isEmpty &&
                        shinchikuURLInput.trimmingCharacters(in: .whitespaces).isEmpty
                    )

                    Button {
                        Task {
                            await store.refresh(modelContext: modelContext)
                        }
                    } label: {
                        Label("今すぐ更新", systemImage: "arrow.clockwise")
                    }
                    .disabled(
                        (store.listURL.isEmpty && store.shinchikuListURL.isEmpty) || store.isRefreshing
                    )
                }

                if let at = store.lastFetchedAt {
                    Section {
                        HStack {
                            Text("最終更新日時")
                            Spacer()
                            Text(at, style: .date)
                            Text(at, style: .time)
                        }
                        .font(ListingObjectStyle.subtitle)
                    }
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

                Section {
                    Link("SUUMO 中古マンション", destination: URL(string: "https://suumo.jp/ms/chuko/")!)
                    Link("SUUMO 新築マンション", destination: URL(string: "https://suumo.jp/ms/shinchiku/")!)
                    Link("HOME'S 中古マンション", destination: URL(string: "https://www.homes.co.jp/mansion/chuko/")!)
                    Link("HOME'S 新築マンション", destination: URL(string: "https://www.homes.co.jp/mansion/shinchiku/")!)
                } header: {
                    Text("参考リンク")
                }

                // アカウント情報 & ログアウト
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
            }
            .alert("保存しました", isPresented: $showSaveConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("一覧の更新時にこのURLから取得します。")
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
