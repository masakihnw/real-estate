import Testing
import Foundation
@testable import RealEstateApp

@Suite("cleanListingName")
struct CleanListingNameTests {

    // MARK: - Bracket Fallback

    @Test("bracket fallback: promotional tags after bracket removal → use bracket content")
    func bracketFallbackPromotionalTags() {
        let input = "【クレヴィア住吉】ペット可×南向き×2015年築"
        let result = Listing.cleanListingName(input)
        #expect(result == "クレヴィア住吉")
    }

    @Test("bracket fallback: empty after bracket removal → use bracket content")
    func bracketFallbackEmpty() {
        let input = "【パークホームズ東陽町】"
        let result = Listing.cleanListingName(input)
        #expect(result == "パークホームズ東陽町")
    }

    @Test("bracket with real name after → no fallback needed")
    func bracketWithRealNameAfter() {
        let input = "【売主物件】プラウドタワー池袋"
        let result = Listing.cleanListingName(input)
        #expect(result == "プラウドタワー池袋")
    }

    @Test("no bracket → normal cleaning")
    func noBracketNormalCleaning() {
        let input = "パークホームズ日本橋人形町三丁目"
        let result = Listing.cleanListingName(input)
        #expect(result == "パークホームズ日本橋人形町三丁目")
    }

    // MARK: - isFeatureTagsOnly

    @Test("feature tags only: ×-separated tags")
    func featureTagsOnlyBasic() {
        #expect(Listing.isFeatureTagsOnly("ペット可×南向き×2015年築"))
    }

    @Test("feature tags only: two tags")
    func featureTagsTwoTags() {
        #expect(Listing.isFeatureTagsOnly("角部屋×駅徒歩5分"))
    }

    @Test("not feature tags: single building name")
    func notFeatureTagsSingleName() {
        #expect(!Listing.isFeatureTagsOnly("クレヴィア住吉"))
    }

    @Test("not feature tags: no × separator")
    func notFeatureTagsNoSeparator() {
        #expect(!Listing.isFeatureTagsOnly("ペット可南向き"))
    }

    // MARK: - Dash Normalization

    @Test("dash normalization: katakana prolonged sound between alphanumeric → ASCII hyphen")
    func dashNormalizationKatakana() {
        let input = "アーデル大塚Cースクエア"
        let result = Listing.cleanListingName(input)
        #expect(result == "アーデル大塚C-スクエア")
    }

    @Test("dash normalization: en dash between alphanumeric → ASCII hyphen")
    func dashNormalizationEnDash() {
        let input = "レーベン五反野1–A"
        let result = Listing.cleanListingName(input)
        #expect(result == "レーベン五反野1-A")
    }

    @Test("dash normalization: katakana prolonged sound in katakana word preserved")
    func dashPreservedInKatakana() {
        let input = "パークホームズ"
        let result = Listing.cleanListingName(input)
        #expect(result == "パークホームズ")
    }

    // MARK: - buildingGroupKey dash unification

    @Test("buildingGroupKey: C-スクエア and Cースクエア produce same key")
    func buildingGroupKeyDashUnification() {
        let listing1 = Listing(source: "test", url: "https://example.com/1", name: "アーデル大塚C-スクエア", address: "東京都豊島区南大塚1-1-1")
        let listing2 = Listing(source: "test", url: "https://example.com/2", name: "アーデル大塚Cースクエア", address: "東京都豊島区南大塚1-1-1")
        #expect(listing1.buildingGroupKey == listing2.buildingGroupKey)
    }

    // MARK: - Existing Behavior Preserved

    @Test("NFKC normalization: fullwidth to halfwidth")
    func nfkcNormalization() {
        // ＡＢＣ → ABC (NFKC), then stripTrailingEnglish removes trailing English
        let input = "パークホームズ123"
        let result = Listing.cleanListingName(input)
        #expect(result == "パークホームズ123")
    }

    @Test("strips 新築マンション prefix")
    func stripsShinkuPrefix() {
        let input = "新築マンションプラウド東陽町"
        let result = Listing.cleanListingName(input)
        #expect(result == "プラウド東陽町")
    }

    @Test("strips floor suffix")
    func stripsFloorSuffix() {
        let input = "パークホームズ池袋 9F"
        let result = Listing.cleanListingName(input)
        #expect(result == "パークホームズ池袋")
    }

    @Test("strips building number suffix")
    func stripsBuildingNumber() {
        let input = "パークホームズ池袋 2号棟"
        let result = Listing.cleanListingName(input)
        #expect(result == "パークホームズ池袋")
    }
}
