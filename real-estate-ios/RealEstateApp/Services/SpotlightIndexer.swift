//
//  SpotlightIndexer.swift
//  RealEstateApp
//
//  CoreSpotlight 連携: いいね済み物件を Spotlight 検索にインデックスし、
//  ユーザーが Spotlight から物件を検索・開けるようにする。
//

import CoreSpotlight
import MobileCoreServices

enum SpotlightIndexer {
    private static let domainIdentifier = "com.hanawa.realestate.listing"

    static func indexListing(_ listing: Listing) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .content)
        attributeSet.title = listing.name
        attributeSet.contentDescription = buildDescription(listing)
        attributeSet.keywords = buildKeywords(listing)

        let item = CSSearchableItem(
            uniqueIdentifier: listing.url,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
        item.expirationDate = Calendar.current.date(byAdding: .month, value: 3, to: .now)

        CSSearchableIndex.default().indexSearchableItems([item])
    }

    static func deindexListing(url: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [url])
    }

    static func reindexAll(_ listings: [Listing]) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in
            let items = listings.filter(\.isLiked).map { listing -> CSSearchableItem in
                let attributeSet = CSSearchableItemAttributeSet(contentType: .content)
                attributeSet.title = listing.name
                attributeSet.contentDescription = buildDescription(listing)
                attributeSet.keywords = buildKeywords(listing)

                let item = CSSearchableItem(
                    uniqueIdentifier: listing.url,
                    domainIdentifier: domainIdentifier,
                    attributeSet: attributeSet
                )
                item.expirationDate = Calendar.current.date(byAdding: .month, value: 3, to: .now)
                return item
            }
            if !items.isEmpty {
                CSSearchableIndex.default().indexSearchableItems(items)
            }
        }
    }

    private static func buildDescription(_ listing: Listing) -> String {
        var parts: [String] = []
        if let price = listing.priceMan {
            parts.append("\(price)万円")
        }
        if let area = listing.areaM2 {
            parts.append(String(format: "%.1f㎡", area))
        }
        if let layout = listing.layout {
            parts.append(layout)
        }
        if let addr = listing.address {
            parts.append(addr)
        }
        return parts.joined(separator: " / ")
    }

    private static func buildKeywords(_ listing: Listing) -> [String] {
        var keywords: [String] = [listing.name]
        if let addr = listing.address { keywords.append(addr) }
        if let layout = listing.layout { keywords.append(layout) }
        if let station = listing.stationLine { keywords.append(station) }
        return keywords
    }
}
