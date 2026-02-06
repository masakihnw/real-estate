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
    @State private var urlInput: String = ""
    @State private var showSaveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("一覧JSONのURL", text: $urlInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onAppear { urlInput = store.listURL }
                } header: {
                    Text("データソース")
                } footer: {
                    Text("scraping-tool の results/latest.json を配信しているURL（GitHub raw や Gist など）を指定してください。")
                }

                Section {
                    Button {
                        store.listURL = urlInput.trimmingCharacters(in: .whitespaces)
                        showSaveConfirmation = true
                    } label: {
                        Label("URLを保存", systemImage: "checkmark.circle")
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        Task {
                            await store.refresh(modelContext: modelContext)
                        }
                    } label: {
                        Label("今すぐ更新", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.listURL.isEmpty || store.isRefreshing)
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

                Section {
                    Link("SUUMO 中古マンション", destination: URL(string: "https://suumo.jp/ms/chuko/")!)
                    Link("HOME'S 中古マンション", destination: URL(string: "https://www.homes.co.jp/chintai/kanto/city/")!)
                } header: {
                    Text("参考リンク")
                }
            }
            .navigationTitle("設定")
            .alert("保存しました", isPresented: $showSaveConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("一覧の更新時にこのURLから取得します。")
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(ListingStore.shared)
        .modelContainer(for: Listing.self, inMemory: true)
}
