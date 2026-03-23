//
//  ListingDetailViewComponents.swift
//  RealEstateApp
//
//  ListingDetailView から切り出したヘルパーコンポーネント群。
//  HazardChip, DetailRow, SafariView, GalleryThumbnailView,
//  GalleryFullScreenView, CommuteCardButtonStyle を含む。
//

import SwiftUI
import SafariServices
import UIKit

// MARK: - ハザードチップ

/// ハザードチップ
struct HazardChip: View {
    let icon: String
    let label: String
    let severity: Listing.HazardSeverity

    private var chipColor: Color {
        switch severity {
        case .danger: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(chipColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            chipColor.opacity(0.12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 詳細行

/// 詳細画面の1行（左ラベル / 右値）。HTML 準拠の1列リストレイアウト。
struct DetailRow: View {
    let title: String
    let value: String
    var accentValue: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(ListingObjectStyle.detailLabel)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(ListingObjectStyle.detailValue)
                .foregroundStyle(accentValue ? Color.accentColor : .primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - SFSafariViewController ラッパー

/// Safari のログイン状態・Cookie を共有した状態で外部サイトを開く。
/// Link(destination:) だと独立した Safari が開き Cookie が共有されないため、
/// SFSafariViewController を使う。
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = .systemBlue
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

// MARK: - ギャラリーサムネイル（余白トリミング済み）

/// ギャラリー用サムネイル。画像を非同期ロードし白余白をトリミングして表示する。
struct GalleryThumbnailView: View {
    let url: URL
    let label: String
    let onTap: () -> Void

    @State private var loadedImage: UIImage?
    @State private var loadPhase: LoadPhase = .loading

    private enum LoadPhase { case loading, success, failure }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                thumbnailContent
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)を拡大表示")
        .task(id: url) {
            await loadAndTrim()
        }
    }

    @State private var showCopiedFeedback = false

    @ViewBuilder
    private var thumbnailContent: some View {
        switch loadPhase {
        case .success:
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 150)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if showCopiedFeedback {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Label("コピーしました", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.green)
                                }
                                .transition(.opacity)
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.image = loadedImage
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            withAnimation { showCopiedFeedback = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { showCopiedFeedback = false }
                            }
                        } label: {
                            Label("画像をコピー", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIActivityViewController.share(image: loadedImage)
                        } label: {
                            Label("共有…", systemImage: "square.and.arrow.up")
                        }
                    }
            }
        case .failure:
            ZStack {
                Color(.systemGray6)
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                    Text("読み込み失敗")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .loading:
            ZStack {
                Color(.systemGray6)
                ProgressView()
            }
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func loadAndTrim() async {
        let cacheKey = url.absoluteString
        if let cached = TrimmedImageCache.shared.image(for: cacheKey) {
            loadedImage = cached
            loadPhase = .success
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let original = UIImage(data: data) else {
                loadPhase = .failure
                return
            }
            let trimmed = original.trimmingWhitespaceBorder()
            TrimmedImageCache.shared.set(trimmed, for: cacheKey)
            loadedImage = trimmed
            loadPhase = .success
        } catch {
            loadPhase = .failure
        }
    }
}

// MARK: - ギャラリーフルスクリーン表示（横スワイプ対応・余白トリミング済み）

/// 物件画像のフルスクリーン表示。横スワイプで前後の画像に移動でき、白余白は自動トリミングされる。
struct GalleryFullScreenView: View {
    let items: [(url: URL, label: String)]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var loadedImages: [Int: UIImage] = [:]
    @State private var failedIndices: Set<Int> = []
    @State private var showCopiedOverlay = false

    init(items: [(url: URL, label: String)], initialIndex: Int) {
        self.items = items
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ZStack {
                        Color.black.ignoresSafeArea()
                        if let image = loadedImages[index] {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(.horizontal, 4)
                                .contextMenu {
                                    Button {
                                        copyCurrentImage()
                                    } label: {
                                        Label("画像をコピー", systemImage: "doc.on.doc")
                                    }
                                    Button {
                                        UIActivityViewController.share(image: image)
                                    } label: {
                                        Label("共有…", systemImage: "square.and.arrow.up")
                                    }
                                }
                        } else if failedIndices.contains(index) {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.largeTitle)
                                Text("画像を読み込めません")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white.opacity(0.6))
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    .tag(index)
                    .task {
                        await loadImage(at: index)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .center) {
                if showCopiedOverlay {
                    Label("コピーしました", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if items.count > 1 {
                    galleryMiniMap
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        if items.count > 1 {
                            Text("\(currentIndex + 1) / \(items.count)")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        if currentIndex >= 0, currentIndex < items.count {
                            Text(items[currentIndex].label)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white.opacity(0.8), .white.opacity(0.2))
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .primaryAction) {
                    if loadedImages[currentIndex] != nil {
                        Button {
                            copyCurrentImage()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onChange(of: currentIndex) { _, newIndex in
            // 前後の画像を先読み
            Task {
                if newIndex > 0 { await loadImage(at: newIndex - 1) }
                if newIndex < items.count - 1 { await loadImage(at: newIndex + 1) }
            }
        }
    }

    private var galleryMiniMap: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentIndex = index
                            }
                        } label: {
                            Group {
                                if let img = loadedImages[index] {
                                    Image(uiImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.15))
                                        .overlay {
                                            ProgressView().tint(.white.opacity(0.5)).scaleEffect(0.5)
                                        }
                                }
                            }
                            .frame(width: 48, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(index == currentIndex ? Color.white : Color.clear, lineWidth: 2)
                            )
                            .opacity(index == currentIndex ? 1.0 : 0.5)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial.opacity(0.8))
            .onChange(of: currentIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func copyCurrentImage() {
        guard let image = loadedImages[currentIndex] else { return }
        UIPasteboard.general.image = image
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.25)) { showCopiedOverlay = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.25)) { showCopiedOverlay = false }
        }
    }

    private func loadImage(at index: Int) async {
        guard index >= 0, index < items.count else { return }
        guard loadedImages[index] == nil, !failedIndices.contains(index) else { return }
        let url = items[index].url
        let cacheKey = url.absoluteString

        if let cached = TrimmedImageCache.shared.image(for: cacheKey) {
            loadedImages[index] = cached
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let original = UIImage(data: data) else {
                failedIndices.insert(index)
                return
            }
            let trimmed = original.trimmingWhitespaceBorder()
            TrimmedImageCache.shared.set(trimmed, for: cacheKey)
            loadedImages[index] = trimmed
        } catch {
            failedIndices.insert(index)
        }
    }
}

// MARK: - UIActivityViewController 共有ヘルパー

extension UIActivityViewController {
    static func share(image: UIImage) {
        let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = windowScene.keyWindow?.rootViewController else { return }
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        root.present(activityVC, animated: true)
    }
}

// MARK: - 通勤カードボタンスタイル

/// 通勤カードのボタンスタイル: 押下時にスケール + 透明度で視覚フィードバック
struct CommuteCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
