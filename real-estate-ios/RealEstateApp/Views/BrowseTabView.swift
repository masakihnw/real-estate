//
//  BrowseTabView.swift
//  RealEstateApp
//
//  「さがす」タブ: 物件一覧と地図をセグメントで切り替える。
//  子View（ListingListView / MapTabView）は各自 NavigationStack を持つため、
//  このViewは NavigationStack を持たない（二重ネスト回避）。
//  切替時の状態保持（スクロール位置・地図カメラ）は Phase 4 の地図刷新で対応。
//

import SwiftUI

struct BrowseTabView: View {
    enum Mode: String, CaseIterable {
        case list
        case map

        var label: String {
            switch self {
            case .list: "リスト"
            case .map:  "地図"
            }
        }
    }

    @SceneStorage("browseMode") private var modeRaw = Mode.list.rawValue

    private var mode: Binding<Mode> {
        Binding(
            get: { Mode(rawValue: modeRaw) ?? .list },
            set: { modeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("表示形式", selection: mode) {
                ForEach(Mode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)

            switch mode.wrappedValue {
            case .list:
                PropertyListingTabView()
            case .map:
                MapTabView()
            }
        }
        .background(Color(.systemBackground))
    }
}

#Preview {
    BrowseTabView()
        .environment(ListingStore.shared)
        .environment(FilterTemplateStore())
}
