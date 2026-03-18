//
//  ListingDetailPagerView.swift
//  RealEstateApp
//
//  全物件スワイプページャー。フィルタ済み物件リストを横スワイプで横断比較可能にする。
//  各ページは既存の ListingDetailView をそのまま表示する。
//
//  パフォーマンス: 現在の1物件のみ ListingDetailView を生成し、
//  スワイプ操作で前後の物件に切り替える。TabView(.page) の全件 ForEach を
//  廃止し、メモリ使用量とビュー生成コストを最小化。
//

import SwiftUI

struct ListingDetailPagerView: View {
    let listings: [Listing]
    @State private var currentIndex: Int
    @GestureState private var dragOffset: CGFloat = 0

    init(listings: [Listing], initialIndex: Int) {
        self.listings = listings
        self._currentIndex = State(initialValue: min(initialIndex, max(listings.count - 1, 0)))
    }

    var body: some View {
        if listings.isEmpty {
            ContentUnavailableView("物件がありません", systemImage: "building.2")
        } else {
            GeometryReader { geometry in
                ListingDetailView(listing: listings[currentIndex])
                    .id(listings[currentIndex].url)
                    .offset(x: dragOffset)
                    .animation(.interactiveSpring(), value: dragOffset)
                    .gesture(swipeGesture(pageWidth: geometry.size.width))
            }
            .overlay(alignment: .bottom) {
                if listings.count > 1 {
                    pageIndicator
                        .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Swipe Gesture

    /// 横スワイプで前後の物件に遷移するジェスチャ。
    /// ScrollView の縦スクロールと競合しないよう、主に水平方向のドラッグのみに反応。
    private func swipeGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 30, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                let h = value.translation.width
                let v = value.translation.height
                guard abs(h) > abs(v) * 1.2 else { return }

                let atLeadingEdge = currentIndex == 0 && h > 0
                let atTrailingEdge = currentIndex == listings.count - 1 && h < 0
                if atLeadingEdge || atTrailingEdge {
                    state = h * 0.3
                } else {
                    state = h
                }
            }
            .onEnded { value in
                let h = value.translation.width
                let v = value.translation.height
                guard abs(h) > abs(v) * 1.2 else { return }

                let threshold = pageWidth * 0.25
                let velocity = value.predictedEndTranslation.width

                withAnimation(.easeOut(duration: 0.25)) {
                    if (h < -threshold || velocity < -threshold) && currentIndex < listings.count - 1 {
                        currentIndex += 1
                    } else if (h > threshold || velocity > threshold) && currentIndex > 0 {
                        currentIndex -= 1
                    }
                }
            }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    currentIndex = max(0, currentIndex - 1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
            }
            .disabled(currentIndex == 0)
            .opacity(currentIndex == 0 ? 0.3 : 1.0)

            Text("\(currentIndex + 1) / \(listings.count)")
                .font(.caption.weight(.medium))
                .monospacedDigit()

            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    currentIndex = min(listings.count - 1, currentIndex + 1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .disabled(currentIndex == listings.count - 1)
            .opacity(currentIndex == listings.count - 1 ? 0.3 : 1.0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

#Preview {
    ListingDetailPagerView(
        listings: [],
        initialIndex: 0
    )
}
