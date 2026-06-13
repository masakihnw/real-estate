import Foundation

/// ウィジェットのタップ遷移用ディープリンク。
///
/// 形式: `realestate://listing?u=<percent-encoded listing.url>`
/// ウィジェット側は同じ形式で URL を組み立て、アプリの onOpenURL がこれを解析して
/// 対象物件（listing.url 一致）を詳細表示する（Spotlight と同じ識別子）。
enum WidgetDeepLink {
    static let scheme = "realestate"
    static let listingHost = "listing"
    static let listingQueryKey = "u"

    /// listing.url から widgetURL を組み立てる。
    static func url(forListingURL listingURL: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = listingHost
        components.queryItems = [URLQueryItem(name: listingQueryKey, value: listingURL)]
        return components.url
    }

    /// 受信 URL から listing.url を取り出す。ディープリンクでなければ nil。
    static func listingURL(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == listingHost else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let value = components?.queryItems?.first(where: { $0.name == listingQueryKey })?.value,
              !value.isEmpty else { return nil }
        return value
    }
}
