//
//  PhotoSectionView.swift
//  RealEstateApp
//
//  物件詳細画面の内見写真セクション。
//  カメラロールから選択、またはカメラで直接撮影して物件に紐づけて保存する。
//

import SwiftUI
import PhotosUI
import SwiftData

struct PhotoSectionView: View {
    let listing: Listing
    @Environment(\.modelContext) private var modelContext

    /// PhotosPicker の選択アイテム
    @State private var selectedPhotoItem: PhotosPickerItem?
    /// カメラ表示フラグ
    @State private var showCamera = false
    /// フルスクリーン表示する写真のインデックス
    @State private var fullscreenPhotoIndex: Int?
    /// 削除確認ダイアログ用
    @State private var photoToDelete: PhotoMeta?

    private let photoStorage = PhotoStorageService.shared

    var body: some View {
        let photos = listing.parsedPhotos

        VStack(alignment: .leading, spacing: 10) {
            // ヘッダー
            HStack {
                Label("内見写真", systemImage: "camera.fill")
                    .font(ListingObjectStyle.detailLabel)
                    .foregroundStyle(.secondary)
                if !photos.isEmpty {
                    Text("(\(photos.count))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                // 追加ボタン群
                HStack(spacing: 12) {
                    // カメラロールから選択
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel("カメラロールから写真を追加")

                    // カメラ起動
                    Button {
                        showCamera = true
                    } label: {
                        Image(systemName: "camera")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel("カメラで撮影")
                }
            }

            // 写真一覧（横スクロール）
            if photos.isEmpty {
                Text("内見写真はまだありません")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            PhotoThumbnailView(
                                photo: photo,
                                listing: listing,
                                onTap: { fullscreenPhotoIndex = index },
                                onDelete: { photoToDelete = photo }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                await handlePhotoSelection(newItem)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                if let image {
                    photoStorage.savePhoto(image, for: listing, modelContext: modelContext)
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $fullscreenPhotoIndex) { index in
            PhotoFullscreenView(
                photos: listing.parsedPhotos,
                listing: listing,
                initialIndex: index
            )
        }
        .alert("写真を削除", isPresented: Binding(
            get: { photoToDelete != nil },
            set: { if !$0 { photoToDelete = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let photo = photoToDelete {
                    photoStorage.deletePhoto(photo, for: listing, modelContext: modelContext)
                    photoToDelete = nil
                }
            }
            Button("キャンセル", role: .cancel) {
                photoToDelete = nil
            }
        } message: {
            Text("この写真を削除しますか？")
        }
    }

    /// PhotosPicker で選択された写真を処理
    @MainActor
    private func handlePhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { selectedPhotoItem = nil }

        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                photoStorage.savePhoto(image, for: listing, modelContext: modelContext)
            }
        } catch {
            print("[PhotoSection] 写真の読み込みに失敗: \(error.localizedDescription)")
        }
    }
}

// MARK: - サムネイル表示

private struct PhotoThumbnailView: View {
    let photo: PhotoMeta
    let listing: Listing
    var onTap: () -> Void
    var onDelete: () -> Void

    private let photoStorage = PhotoStorageService.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                Group {
                    if let image = photoStorage.loadImage(for: photo, listing: listing) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color(.systemGray5))
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            // 削除ボタン
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(.systemGray3))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("写真を削除")
        }
    }
}

// MARK: - フルスクリーン写真表示

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

private struct PhotoFullscreenView: View {
    let photos: [PhotoMeta]
    let listing: Listing
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int

    init(photos: [PhotoMeta], listing: Listing, initialIndex: Int) {
        self.photos = photos
        self.listing = listing
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: initialIndex)
    }

    private let photoStorage = PhotoStorageService.shared

    var body: some View {
        NavigationStack {
            TabView(selection: $currentIndex) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    if let image = photoStorage.loadImage(for: photo, listing: listing) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .tag(index)
                    } else {
                        Color(.systemGray6)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(.tertiary)
                            }
                            .tag(index)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("\(currentIndex + 1) / \(photos.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - カメラ撮影（UIImagePickerController ラッパー）

struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onCapture(image)
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
            picker.dismiss(animated: true)
        }
    }
}
