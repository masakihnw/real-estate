//
//  PropertyListingTabView.swift
//  RealEstateApp
//
//  物件タブのルートビュー。中古マンションのみ表示。
//

import SwiftUI

struct PropertyListingTabView: View {
    var body: some View {
        ListingListView(propertyTypeFilter: "chuko")
    }
}
