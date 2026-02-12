//
//  ScrapingLogView.swift
//  RealEstateApp
//
//  最新のスクレイピングログを表示し、ワンタップでコピーできる画面。
//  コピーしたログを Cursor に貼り付けて問題を診断できる。
//
//  巨大ログを効率的に表示するため UITextView を使用。

import SwiftUI
import UIKit

// MARK: - UITextView ラッパー（大量テキストを効率的に表示）

/// SwiftUI の `Text` は巨大文字列のレイアウトでメインスレッドをブロックする。
/// UIKit の `UITextView` はテキストレンダリングが最適化されており、
/// 可視領域のみを描画するため巨大ログでも高速に表示できる。
private struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false          // 外側の ScrollView に委ねる
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.backgroundColor = .systemGray6
        tv.layer.cornerRadius = 8
        tv.layer.masksToBounds = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .label
        // リンク検出を無効化（パフォーマンス向上）
        tv.dataDetectorTypes = []
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // テキストが同じなら更新をスキップ
        if uiView.text != text {
            uiView.text = text
        }
    }
}

// MARK: - ScrapingLogView

struct ScrapingLogView: View {
    @Environment(\.dismiss) private var dismiss

    private let logService = ScrapingLogService.shared

    @State private var copied = false
    /// ログ本文を遅延表示するためのフラグ
    @State private var showLogBody = false

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

                // ログ本文（遅延表示）
                if showLogBody {
                    logBody(log)
                        .transition(.opacity)
                } else {
                    ProgressView("ログを表示中...")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .padding()
        }
        .refreshable {
            showLogBody = false
            await logService.fetch()
            // 再取得後に少し遅延してログ本文を表示
            try? await Task.sleep(for: .milliseconds(100))
            showLogBody = true
        }
        .onAppear {
            // UIが先に表示された後、次のランループでログ本文を表示
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeIn(duration: 0.2)) {
                    showLogBody = true
                }
            }
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

    // MARK: - ログ本文（UITextView で効率的に描画）

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

            LogTextView(text: log.log)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
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
