import SwiftUI

struct SwipeCompletionView: View {
    let likedCount: Int
    let nopedCount: Int
    let skippedCount: Int
    let likedListings: [Listing]
    let onSelectListing: (Listing) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("チェック完了")
                .font(.title2.bold())

            statsRow

            if !likedListings.isEmpty {
                likedSection
            }

            Spacer()

            Button(action: onDismiss) {
                Text("閉じる")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
        }
        .padding()
    }

    private var statsRow: some View {
        HStack(spacing: 32) {
            statBadge(count: likedCount, label: "Like", color: .yellow, icon: "heart.fill")
            statBadge(count: nopedCount, label: "Nope", color: .orange, icon: "xmark")
            if skippedCount > 0 {
                statBadge(count: skippedCount, label: "Skip", color: .gray, icon: "arrow.down")
            }
        }
    }

    private func statBadge(count: Int, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text("\(count)")
                    .font(.title3.bold())
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var likedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Likeした物件")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(likedListings) { listing in
                        Button { onSelectListing(listing) } label: {
                            likedCard(listing)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func likedCard(_ listing: Listing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: listing.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 80)
                        .clipped()
                default:
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 120, height: 80)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(listing.nameWithFloor)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(listing.priceDisplayCompact)
                .font(.caption2.bold())
                .foregroundStyle(Color.accentColor)
        }
    }
}
