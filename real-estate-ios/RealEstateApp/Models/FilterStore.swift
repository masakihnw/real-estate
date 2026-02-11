//
//  FilterStore.swift
//  RealEstateApp
//
//  タブ間で共有されるフィルタ状態。
//  ContentView で .environment() として注入し、各タブで参照する。
//

import SwiftUI

@Observable
final class FilterStore {
    /// 後方互換用。新規 View は独自インスタンスを生成して OOUI タブ間独立を保つこと。
    static let shared = FilterStore()

    var filter = ListingFilter()

    /// フィルタシートの表示状態
    var showFilterSheet = false

    /// OOUI: タブごとに独立したフィルタ状態を持てるように init を公開
    init() {}
}
