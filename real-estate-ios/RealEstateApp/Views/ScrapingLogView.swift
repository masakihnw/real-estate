//
//  ScrapingLogView.swift
//  RealEstateApp
//
//  最新のスクレイピングログを表示し、ワンタップでコピーできる画面。
//  コピーしたログを Cursor に貼り付けて問題を診断できる。
//

import SwiftUI

struct ScrapingLogView: View {
    @Environment(\.dismiss) private var dismiss

    private let logService = ScrapingLogService.shared

    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if logService.isLoading {
                    ProgressView("ログを読み込み中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let log = logService.latestLog {
                    logContent(log)
                } else if let error = logService.lastError {
                    ContentUnavailableView {
                        Label("ログを取得できません", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("再試行") {
                            Task { await logService.fetch() }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("ログがありません", systemImage: "doc.text")
                    } description: {
                        Text("スクレイピングが実行されるとログが表示されます。")
                    }
                }
            }
            .navigationTitle("スクレイピングログ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                if logService.latestLog != nil {
                    ToolbarItem(placement: .primaryAction) {
                        copyButton
                    }
                }
            }
            .task {
                await logService.fetch()
            }
        }
    }

    // MARK: - ログ本体

    @ViewBuilder
    private func logContent(_ log: ScrapingLog) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // ヘッダー: ステータス・日時
                headerCard(log)

                // コピーボタン（目立つ位置に配置）
                mainCopyButton(log)

                // ログ本文
                logBody(log)
            }
            .padding()
        }
        .refreshable {
            await logService.fetch()
        }
    }

    // MARK: - ヘッダーカード

    @ViewBuilder
    private func headerCard(_ log: ScrapingLog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: log.statusIcon)
                    .foregroundStyle(log.status == "success" ? .green : log.status == "error" ? .red : .secondary)
                    .font(.title3)
                Text(log.statusLabel)
                    .font(.headline)
                Spacer()
            }

            if !log.formattedTimestamp.isEmpty {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(log.formattedTimestamp)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if log.truncated {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("ログが長いため先頭が省略されています")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - メインコピーボタン

    @ViewBuilder
    private func mainCopyButton(_ log: ScrapingLog) -> some View {
        Button {
            copyLog(log)
        } label: {
            HStack {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "コピーしました" : "ログ全文をコピー")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(copied ? .green : .blue)
    }

    // MARK: - ログ本文

    @ViewBuilder
    private func logBody(_ log: ScrapingLog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ログ")
                    .font(.headline)
                Spacer()
                Text("\(log.log.count) 文字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(log.log)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - ツールバーコピーボタン

    private var copyButton: some View {
        Button {
            if let log = logService.latestLog {
                copyLog(log)
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
    }

    // MARK: - コピー処理

    private func copyLog(_ log: ScrapingLog) {
        UIPasteboard.general.string = log.copyText
        withAnimation {
            copied = true
        }
        // 2秒後にリセット
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                copied = false
            }
        }
    }
}

#Preview {
    ScrapingLogView()
}
