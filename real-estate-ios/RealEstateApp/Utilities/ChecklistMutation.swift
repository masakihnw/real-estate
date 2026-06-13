import Foundation

/// 内見チェックリストのトグル/エンコードの純ロジック。
/// ListingDetailView の private な toggleChecklistItem（saveContext と混在しテスト不能）と
/// InspectionChecklistView の重複を避け、両者から呼べる副作用なしの関数に切り出す。
enum ChecklistMutation {
    /// 指定 id の isChecked を反転した配列を返す。
    /// items が空（未編集）なら defaultTemplate を起点にする（初回トグルで一覧が確定）。
    static func toggled(_ items: [Listing.ChecklistItem], itemId: String) -> [Listing.ChecklistItem] {
        let base = items.isEmpty ? Listing.ChecklistItem.defaultTemplate : items
        return base.map { item in
            guard item.id == itemId else { return item }
            var copy = item
            copy.isChecked.toggle()
            return copy
        }
    }

    /// チェックリストを JSON 文字列にエンコード（checklistJSON へ保存する形）。
    static func encode(_ items: [Listing.ChecklistItem]) -> String? {
        guard let data = try? JSONEncoder().encode(items) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 表示用に「未編集なら defaultTemplate」を返す（空配列の代わりに10項目）。
    static func display(_ items: [Listing.ChecklistItem]) -> [Listing.ChecklistItem] {
        items.isEmpty ? Listing.ChecklistItem.defaultTemplate : items
    }

    /// チェック済み件数。
    static func checkedCount(_ items: [Listing.ChecklistItem]) -> Int {
        items.filter(\.isChecked).count
    }
}
