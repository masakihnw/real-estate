import Testing
import Foundation
@testable import RealEstateApp

/// get_listing_detail（SETOF listings_feed）は jsonb 列をオブジェクト/配列のまま返す。
/// 旧 DTO は alt_sources を [String]? としていたため型不一致で decode が throw し、
/// その物件の enrichment（画像含む）が一切読めず、スワイプに出ない/件数だけ残る不具合があった。
@Suite("ListingDetail decode (jsonb tolerance)")
struct ListingDetailDecodeTests {

    /// get_listing_detail の実形状に近い JSON。alt_sources/extracted_features/
    /// image_categories/ai_scoring_reasoning がオブジェクト/配列で届く。
    private let detailJSON = """
    [{
      "identity_key": "テストタワー|2LDK|60.0|中野区中野5|2001|3",
      "url": "https://suumo.jp/ms/chuko/tokyo/sc_nakano/nc_x/",
      "name": "テストタワー",
      "property_type": "chuko",
      "price_man": 8980,
      "suumo_images": [
        {"url": "https://e.com/ext.jpg", "label": "現地外観写真"},
        {"url": "https://e.com/liv.jpg", "label": "リビング"}
      ],
      "floor_plan_images": ["https://e.com/floor.jpg"],
      "extracted_features": {"notable_points": "角住戸", "equipment_highlights": ["床暖房"]},
      "image_categories": [
        {"url": "https://e.com/ext.jpg", "category": "exterior", "quality_score": 0.8, "is_junk": false}
      ],
      "ai_scoring_reasoning": {"exit": {"score": 58}, "strengths": ["立地"]},
      "alt_sources": [{"url": "https://suumo.jp/ms/chuko/tokyo/sc_nakano/nc_x/", "source": "suumo"}],
      "alt_sources_json": null,
      "price_history_json": null,
      "has_property_images": true,
      "has_floor_plan_images": true
    }]
    """.data(using: .utf8)!

    @Test("jsonb がオブジェクト/配列でも throw せずデコードできる")
    func decodesWithoutThrowing() throws {
        let dtos = try SupabaseListingStore.decodeDTOs(from: detailJSON)
        #expect(dtos.count == 1)
    }

    @Test("デコード後、外観写真と間取り図が載りスワイプ可能になる")
    func imagesAreLoaded() throws {
        let dtos = try SupabaseListingStore.decodeDTOs(from: detailJSON)
        let listing = try #require(Listing.from(dto: dtos[0], fetchedAt: Date()))
        #expect(listing.hasSuumoImages, "外観写真がデコードされている")
        #expect(listing.hasFloorPlanImages, "間取り図がデコードされている")
        #expect(listing.hasSwipeableImages, "スワイプ表示の必須条件を満たす")
    }

    @Test("alt_sources（オブジェクト配列）が altSourcesJSON に保持される")
    func altSourcesPreserved() throws {
        let dtos = try SupabaseListingStore.decodeDTOs(from: detailJSON)
        let listing = try #require(Listing.from(dto: dtos[0], fetchedAt: Date()))
        #expect(listing.altSourcesJSON?.contains("suumo") == true)
    }
}
