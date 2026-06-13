import Testing
import Foundation
@testable import RealEstateApp

@Suite("ChecklistMutation 内見チェックリスト")
struct ChecklistMutationTests {

    @Test("空配列からのトグルは defaultTemplate を起点に該当項目を反転")
    func toggleFromEmptyUsesTemplate() {
        let result = ChecklistMutation.toggled([], itemId: "noise")
        #expect(result.count == Listing.ChecklistItem.defaultTemplate.count)
        #expect(result.first { $0.id == "noise" }?.isChecked == true)
        // 他の項目は false のまま
        #expect(result.first { $0.id == "sunlight" }?.isChecked == false)
    }

    @Test("既存配列のトグルは該当項目のみ反転")
    func toggleExisting() {
        let items = Listing.ChecklistItem.defaultTemplate
        let once = ChecklistMutation.toggled(items, itemId: "view")
        #expect(once.first { $0.id == "view" }?.isChecked == true)
        let twice = ChecklistMutation.toggled(once, itemId: "view")
        #expect(twice.first { $0.id == "view" }?.isChecked == false)
    }

    @Test("存在しない id は何も変えない")
    func toggleUnknownIdNoChange() {
        let items = Listing.ChecklistItem.defaultTemplate
        let result = ChecklistMutation.toggled(items, itemId: "does-not-exist")
        #expect(result.filter(\.isChecked).isEmpty)
    }

    @Test("encode→decode で往復一致")
    func encodeRoundTrip() {
        let items = ChecklistMutation.toggled([], itemId: "water")
        let json = ChecklistMutation.encode(items)
        #expect(json != nil)
        let decoded = (try? JSONDecoder().decode([Listing.ChecklistItem].self, from: json!.data(using: .utf8)!)) ?? []
        #expect(decoded.first { $0.id == "water" }?.isChecked == true)
        #expect(decoded.count == items.count)
    }

    @Test("display は空配列で defaultTemplate、非空でそのまま")
    func display() {
        #expect(ChecklistMutation.display([]).count == Listing.ChecklistItem.defaultTemplate.count)
        let one = ChecklistMutation.toggled([], itemId: "smell")
        #expect(ChecklistMutation.display(one).count == one.count)
    }

    @Test("checkedCount はチェック済み件数")
    func checkedCount() {
        var items = ChecklistMutation.toggled([], itemId: "noise")
        items = ChecklistMutation.toggled(items, itemId: "view")
        #expect(ChecklistMutation.checkedCount(items) == 2)
        #expect(ChecklistMutation.checkedCount([]) == 0)
    }
}
