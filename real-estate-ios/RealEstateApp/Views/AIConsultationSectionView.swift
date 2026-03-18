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
    @State private var floorPlanCopied = false
    @State private var floorPlanImage: UIImage?

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

        /// アプリ固有の URL スキーム候補（優先度順に試行）
        var appSchemeURLs: [URL] {
            switch self {
            case .chatgpt: return []
            case .gemini: return [
                URL(string: "googlegemini://")!,
                URL(string: "googleapp://robin")!,
            ]
            case .claude: return [
                URL(string: "claude://")!,
            ]
            }
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

    private var hasFloorPlan: Bool { listing.hasFloorPlanImages }

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

            if hasFloorPlan {
                floorPlanCopyButton
            }

            Divider()

            Text("AI サービスで相談")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            if hasFloorPlan && floorPlanImage != nil {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.min")
                    Text("ChatGPT: 間取り図を自動コピー → 貼り付けで添付\nGemini/Claude: プロンプト貼り付け後、戻って間取り図をコピー")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.vertical, 2)
            }

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
        .task { await loadFloorPlanImage() }
    }

    // MARK: - 間取り図コピーボタン

    @ViewBuilder
    private var floorPlanCopyButton: some View {
        Button {
            if let img = floorPlanImage {
                UIPasteboard.general.image = img
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeInOut(duration: 0.3)) { floorPlanCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.3)) { floorPlanCopied = false }
                }
            }
        } label: {
            HStack {
                Image(systemName: floorPlanCopied ? "checkmark" : "photo.on.rectangle")
                Text(floorPlanCopied ? "間取り図をコピーしました" : "間取り図をコピー")
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(floorPlanCopied ? .green : .orange)
        .disabled(floorPlanImage == nil)
    }

    private func loadFloorPlanImage() async {
        guard let url = listing.parsedFloorPlanImages.first else { return }
        let cacheKey = url.absoluteString
        if let cached = TrimmedImageCache.shared.image(for: cacheKey) {
            floorPlanImage = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let original = UIImage(data: data) else { return }
            let trimmed = original.trimmingWhitespaceBorder()
            TrimmedImageCache.shared.set(trimmed, for: cacheKey)
            floorPlanImage = trimmed
        } catch {}
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
                        Text(feedbackText(for: service))
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Text(descriptionText(for: service))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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

    // MARK: - ボタン説明テキスト

    private func descriptionText(for service: AIService) -> String {
        switch service {
        case .chatgpt:
            return floorPlanImage != nil
                ? "プロンプト入力済み＋間取り図コピーで開きます"
                : "プロンプト入力済みで開きます"
        case .gemini, .claude:
            return "プロンプトをコピーして\(service.rawValue)を開きます"
        }
    }

    private func feedbackText(for service: AIService) -> String {
        switch service {
        case .chatgpt:
            return floorPlanImage != nil
                ? "プロンプト入力済み → 間取り図を貼り付けてください"
                : "プロンプト入力済みで開きました"
        case .gemini, .claude:
            return "プロンプトをコピーしました → 貼り付けてください"
        }
    }

    // MARK: - AI サービス起動

    private func openAIService(_ service: AIService) {
        let prompt = listing.toAIConsultationPrompt(otherCandidates: otherCandidates)

        // ChatGPT: テキストは URL プリフィル → クリップボードに画像のみ
        // Gemini/Claude: テキストをクリップボード（画像は別途コピーボタンで対応）
        if service.supportsURLPrefill {
            if let img = floorPlanImage {
                UIPasteboard.general.image = img
            }
        } else {
            UIPasteboard.general.string = prompt
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.3)) { copiedType = .ai(service) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            openServiceApp(service, prompt: prompt)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                if copiedType == .ai(service) { copiedType = nil }
            }
        }
    }

    /// アプリ URL スキーム候補を順に試行し、全て失敗なら Web URL を開く
    private func openServiceApp(_ service: AIService, prompt: String) {
        if service.supportsURLPrefill, let prefillURL = service.prefillURL(prompt: prompt) {
            UIApplication.shared.open(prefillURL)
            return
        }

        let candidates = service.appSchemeURLs
        tryOpenURL(candidates: candidates, index: 0, fallback: service.webURL)
    }

    private func tryOpenURL(candidates: [URL], index: Int, fallback: URL) {
        guard index < candidates.count else {
            UIApplication.shared.open(fallback)
            return
        }
        let url = candidates[index]
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                tryOpenURL(candidates: candidates, index: index + 1, fallback: fallback)
            }
        }
    }
}
