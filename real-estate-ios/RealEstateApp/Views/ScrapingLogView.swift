//
//  ScrapingLogView.swift
//  RealEstateApp
//
//  最新のスクレイピングログを表示し、ワンタップでコピーできる画面。
//  コピーしたログを Cursor に貼り付けて問題を診断できる。
//
//  ステータス・日時を最優先で表示し、ログ本文は折りたたみ式。

import SwiftUI
import UIKit

// MARK: - UITextView ラッパー（大量テキストを効率的に表示）

private struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true   // 内部スクロール
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.backgroundColor = .systemGray6
        tv.layer.cornerRadius = 8
        tv.layer.masksToBounds = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .label
        tv.dataDetectorTypes = []
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
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
    /// ログ本文の展開状態
    @State private var isLogExpanded = false

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
        VStack(spacing: 0) {
            // ── 上部: ステータス・日時・コピー（常に表示、スクロールしない） ──
            VStack(spacing: 16) {
                statusCard(log)
                mainCopyButton(log)
            }
            .padding()

            Divider()

            // ── 下部: ログ本文（折りたたみ式） ──
            logSection(log)
        }
        .refreshable {
            await logService.fetch()
        }
    }

    // MARK: - ステータスカード（目立つ大きめ表示）

    @ViewBuilder
    private func statusCard(_ log: ScrapingLog) -> some View {
        VStack(spacing: 16) {
            // ステータスアイコン + ラベル
            VStack(spacing: 8) {
                Image(systemName: log.statusIcon)
                    .font(.system(size: 48))
                    .foregroundStyle(statusColor(log))

                Text(log.statusLabel)
                    .font(.title2.bold())
                    .foregroundStyle(statusColor(log))
            }

            // 日時
            if !log.formattedTimestamp.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(log.formattedTimestamp)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // 省略注意
            if log.truncated {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("ログが長いため先頭が省略されています")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusColor(_ log: ScrapingLog) -> Color {
        switch log.status {
        case "success": return .green
        case "error": return .red
        default: return .secondary
        }
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

    // MARK: - ログ本文セクション（折りたたみ式）

    @ViewBuilder
    private func logSection(_ log: ScrapingLog) -> some View {
        VStack(spacing: 0) {
            // 展開/折りたたみトグル
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isLogExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isLogExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("ログ本文")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text("\(log.log.count) 文字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isLogExpanded {
                LogTextView(text: log.log)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: isLogExpanded ? .infinity : nil)
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
