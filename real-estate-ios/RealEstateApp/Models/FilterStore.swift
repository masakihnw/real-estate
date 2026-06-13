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

    /// 適用中の保存フィルタ（チップのハイライト用）。
    /// filter がテンプレートと一致しなくなったら View 側で nil に戻す。
    /// Equatable 全比較でなく ID で判定する（同一条件のテンプレート重複や
    /// ローン設定差分による偽陰性を避けるため）。
    var appliedTemplateID: UUID?

    /// OOUI: タブごとに独立したフィルタ状態を持てるように init を公開
    init() {}
}

// MARK: - フィルタテンプレート

struct FilterTemplate: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var filter: ListingFilter
    var createdAt: Date

    init(name: String, filter: ListingFilter) {
        self.id = UUID()
        self.name = name
        self.filter = filter
        self.createdAt = Date()
    }
}

// MARK: - テンプレートストア（UserDefaults 永続化）

@Observable
final class FilterTemplateStore {
    static let maxTemplates = 5
    private static let storageKey = "realestate.filterTemplates"

    private(set) var templates: [FilterTemplate] = []

    var canSave: Bool { templates.count < Self.maxTemplates }

    init() { load() }

    func save(name: String, filter: ListingFilter) {
        guard canSave else { return }
        let template = FilterTemplate(name: name, filter: filter)
        templates.append(template)
        persist()
    }

    func delete(_ template: FilterTemplate) {
        templates.removeAll { $0.id == template.id }
        persist()
    }

    func rename(_ template: FilterTemplate, to newName: String) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[idx].name = newName
        persist()
    }

    /// 永続化済みテンプレートを読み出す（environment 外からの読み取り用。
    /// 例: ListingStore の条件マッチ通知判定）。書き込みは environment 側
    /// インスタンスに限定する。
    static func loadPersisted() -> [FilterTemplate] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FilterTemplate].self, from: data) else { return [] }
        return decoded
    }

    private func load() {
        templates = Self.loadPersisted()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
