import SwiftUI

struct CategorizedImageGallery: View {
    let listing: Listing

    @State private var selectedCategory: String?
    @State private var selectedImageURL: String?

    private var categories: [Listing.ImageCategoryGroup] {
        listing.parsedImageCategories
    }

    var body: some View {
        if !categories.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("物件写真")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    AIIndicator()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories) { group in
                            CategoryTab(
                                title: group.localizedCategory,
                                count: group.images.count,
                                isSelected: selectedCategory == group.category || (selectedCategory == nil && group.category == categories.first?.category)
                            ) {
                                selectedCategory = group.category
                            }
                        }
                    }
                }

                let activeCategory = selectedCategory ?? categories.first?.category ?? ""
                let images = categories.first(where: { $0.category == activeCategory })?.images ?? []

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(images) { image in
                            if let url = URL(string: image.url) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 160, height: 120)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    case .failure:
                                        placeholder
                                    case .empty:
                                        ProgressView()
                                            .frame(width: 160, height: 120)
                                    @unknown default:
                                        placeholder
                                    }
                                }
                                .onTapGesture {
                                    selectedImageURL = image.url
                                }
                            }
                        }
                    }
                }
                .frame(height: 120)
            }
            .fullScreenCover(item: $selectedImageURL) { urlString in
                if let url = URL(string: urlString) {
                    FullScreenImageView(url: url)
                }
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray5))
            .frame(width: 160, height: 120)
            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

private struct CategoryTab: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct FullScreenImageView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                case .empty:
                    ProgressView().tint(.white)
                @unknown default:
                    EmptyView()
                }
            }
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
    }
}
