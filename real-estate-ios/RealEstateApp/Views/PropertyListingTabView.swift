//
//  PropertyListingTabView.swift
//  RealEstateApp
//
//  物件タブのルートビュー。中古・新築をセグメントピッカーで切り替える。
//  従来の ContentView で別タブだった中古・新築を1タブに統合。
//

import SwiftUI

struct PropertyListingTabView: View {
    @State private var propertyType: PropertyType = .chuko

    enum PropertyType: String, CaseIterable {
        case chuko = "中古"
        case shinchiku = "新築"
    }

    var body: some View {
        VStack(spacing: 0) {
            // セグメントピッカー
            Picker("物件種別", selection: $propertyType) {
                ForEach(PropertyType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // コンテンツ
            switch propertyType {
            case .chuko:
                ListingListView(propertyTypeFilter: "chuko")
            case .shinchiku:
                ListingListView(propertyTypeFilter: "shinchiku")
            }
        }
    }
}
