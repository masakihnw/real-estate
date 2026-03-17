//
//  AIConsultationSectionView.swift
//  RealEstateApp
//
//  物件詳細画面から生成 AI（ChatGPT / Gemini / Claude）に相談するための
//  Markdown コピー・AI サービス起動セクション。
//

import SwiftUI
import SwiftData

struct AIConsultationSectionView: View {
    let listing: Listing
    @Query(filter: #Predicate<Listing> { $0.isLiked == true }) private var likedListings: [Listing]
    @State private var copiedType: CopiedType?

    private enum CopiedType: Equatable {
        case markdown
        case ai(AIService)
    }

    enum AIService: String, CaseIterable {
        case chatgpt = "ChatGPT"
        case gemini = "Gemini"
        case claude = "Claude"

        var logoAsset: String {
            switch self {
            case .chatgpt: return "logo-chatgpt"
            case .gemini: return "logo-gemini"
            case .claude: return "logo-claude"
            }
        }

        var fallbackIcon: String {
            switch self {
            case .chatgpt: return "bubble.left.and.text.bubble.right"
            case .gemini: return "sparkles"
            case .claude: return "brain.head.profile"
            }
        }

        var color: Color {
            switch self {
            case .chatgpt: return Color(red: 0.07, green: 0.66, blue: 0.56)
            case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
            case .claude: return Color(red: 0.85, green: 0.55, blue: 0.35)
            }
        }

        /// ChatGPT は `?q=` パラメータでプロンプトをプリフィル可能。
        /// Gemini / Claude は URL プリフィル非対応のためクリップボード経由。
        var supportsURLPrefill: Bool {
            self == .chatgpt
        }

        var webURL: URL {
            switch self {
            case .chatgpt: return URL(string: "https://chatgpt.com/")!
            case .gemini: return URL(string: "https://gemini.google.com/app")!
            case .claude: return URL(string: "https://claude.ai/new")!
            }
        }

        func prefillURL(prompt: String) -> URL? {
            guard supportsURLPrefill else { return nil }
            guard let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
            return URL(string: "https://chatgpt.com/?q=\(encoded)")
        }
    }

    private var otherCandidates: [Listing] {
        likedListings
            .filter { $0.url != listing.url }
            .sorted { ($0.viewedAt ?? .distantPast) > ($1.viewedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI に相談", systemImage: "brain")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(Color.accentColor)

            Text("物件情報を生成 AI にコピーして、購入判断やリスク分析の壁打ちができます")
                .font(.caption)
                .foregroundStyle(.secondary)

            markdownCopyButton

            Divider()

            Text("AI サービスで相談")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            ForEach(AIService.allCases, id: \.rawValue) { service in
                aiServiceButton(service)
            }

            if !otherCandidates.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("お気に入り物件 \(otherCandidates.count)件の概要も含めてコピーされます")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .tintedGlassBackground(tint: Color.accentColor, tintOpacity: 0.03, borderOpacity: 0.08)
    }

    // MARK: - Markdown コピーボタン

    @ViewBuilder
    private var markdownCopyButton: some View {
        Button {
            let md = listing.toMarkdown()
            UIPasteboard.general.string = md
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.3)) { copiedType = .markdown }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    if copiedType == .markdown { copiedType = nil }
                }
            }
        } label: {
            HStack {
                Image(systemName: copiedType == .markdown ? "checkmark" : "doc.on.doc")
                Text(copiedType == .markdown ? "コピーしました" : "Markdown でコピー")
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(copiedType == .markdown ? .green : .accentColor)
    }

    // MARK: - AI サービスボタン

    private func aiServiceButton(_ service: AIService) -> some View {
        Button {
            openAIService(service)
        } label: {
            HStack(spacing: 10) {
                serviceLogoView(service)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(service.rawValue) で相談")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if copiedType == .ai(service) {
                        if service.supportsURLPrefill {
                            Text("プロンプト入力済みで開きました")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Text("プロンプトをコピーしました → 貼り付けてください")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    } else {
                        if service.supportsURLPrefill {
                            Text("プロンプト入力済みで\(service.rawValue)を開きます")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("プロンプトをコピーして\(service.rawValue)を開きます")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(copiedType == .ai(service) ? service.color.opacity(0.08) : Color(.systemGray6))
            )
        }
        .buttonStyle(.plain)
    }

    /// ロゴ画像を表示。アセットがない場合は SF Symbol にフォールバック。
    @ViewBuilder
    private func serviceLogoView(_ service: AIService) -> some View {
        let img = UIImage(named: service.logoAsset)
        if let img {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: service.fallbackIcon)
                .font(.body)
                .foregroundStyle(service.color)
        }
    }

    // MARK: - AI サービス起動

    private func openAIService(_ service: AIService) {
        let prompt = listing.toAIConsultationPrompt(otherCandidates: otherCandidates)

        UIPasteboard.general.string = prompt
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        withAnimation(.easeInOut(duration: 0.3)) { copiedType = .ai(service) }

        if service.supportsURLPrefill, let prefillURL = service.prefillURL(prompt: prompt) {
            // ChatGPT: プロンプト入力済みの URL で開く（アプリがあればアプリが開く）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                UIApplication.shared.open(prefillURL)
            }
        } else {
            // Gemini / Claude: クリップボードにコピー済み → アプリ or Web を開く
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UIApplication.shared.open(service.webURL)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                if copiedType == .ai(service) { copiedType = nil }
            }
        }
    }
}
