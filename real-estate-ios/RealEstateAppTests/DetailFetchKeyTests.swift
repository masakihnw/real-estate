import Testing
import Foundation
@testable import RealEstateApp

/// 詳細 enrichment フェッチ（get_listing_detail RPC）のキー選択に関する回帰テスト。
///
/// DB の identity_key は6要素（name|layout|area|address|year|floor）。
/// 一方 Swift computed identityKey は user_annotations 用の5要素（階数を含まない）。
/// 両者は別物で、RPC には DB 由来の supabaseIdentityKey を使わなければ
/// 常に0件マッチ → enrichment（画像含む）が一切ロードされない不具合になる。
@Suite("Detail Fetch Key")
struct DetailFetchKeyTests {

    @Test("supabaseIdentityKey は DB の6要素 identity_key を保持し、computed identityKey とは異なる")
    func supabaseIdentityKeyHoldsDBKey() throws {
        let dbKey = "テストマンション|2LDK|57.49|中央区湊3|2000|6"
        let json = """
        {"identity_key": "\(dbKey)", "url": "https://suumo.jp/x", "name": "テストマンション",
         "layout": "2LDK", "area_m2": 57.49, "address": "中央区湊3",
         "built_year": 2000, "floor_position": 6}
        """
        let dto = try JSONDecoder().decode(ListingDTO.self, from: Data(json.utf8))
        let listing = try #require(Listing.from(dto: dto))

        // DB キーがそのまま保持される（RPC はこれで引く）
        #expect(listing.supabaseIdentityKey == dbKey)
        // computed identityKey は階数を含まない5要素なので DB キーと一致しない
        #expect(listing.identityKey != dbKey)
        #expect(listing.identityKey != listing.supabaseIdentityKey)
    }
}
