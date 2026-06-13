import Foundation
import ImageIO
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "WidgetImage")

/// ウィジェット用の「今日の1枚」画像を App Group コンテナへ保存する。
///
/// ウィジェット拡張は ~30MB のメモリ制約があり AsyncImage も非推奨のため、
/// アプリ側でダウンサンプルした JPEG をローカルファイルとして共有し、
/// ウィジェットは `Image(contentsOfFile:)` で読む。
enum WidgetImageStore {
    static let suiteName = "group.com.hanawa.realestate"
    /// ウィジェット描画幅の約2倍。メモリ節約のためデコード時にこのサイズへ縮小する。
    private static let maxPixelSize = 600
    private static let downloadTimeout: TimeInterval = 3

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    /// listing.url から安定したファイル名を作る（同一物件は同名で上書き、履歴を増やさない）。
    static func fileName(forListingURL listingURL: String) -> String {
        "featured-\(stableHash(listingURL)).jpg"
    }

    /// 画像をダウンロード→ダウンサンプル→保存し、保存したファイル名を返す。
    /// 失敗時は nil（呼び出し側は no-image レイアウトにフォールバック）。
    /// 保存に成功したら、それ以外の featured-*.jpg を掃除する。
    static func store(fromURLString urlString: String, listingURL: String) async -> String? {
        guard let container = containerURL, let url = URL(string: urlString) else { return nil }
        let name = fileName(forListingURL: listingURL)
        let dest = container.appendingPathComponent(name)

        // 同一物件の画像が保存済みなら再ダウンロードしない（前景更新の度の無駄な通信・遅延を回避）。
        if FileManager.default.fileExists(atPath: dest.path) {
            cleanup(keeping: name, in: container)
            return name
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = downloadTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let jpeg = downsampledJPEG(from: data) else {
                logger.info("featured 画像のデコードに失敗")
                return nil
            }
            try jpeg.write(to: dest, options: .atomic)
            cleanup(keeping: name, in: container)
            return name
        } catch {
            logger.info("featured 画像の取得に失敗: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private

    /// デコード時に縮小して JPEG 化する（フルデコードを避けメモリを抑える）。
    private static func downsampledJPEG(from data: Data) -> Data? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let props = [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        CGImageDestinationAddImage(dest, thumb, props)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 現在の featured 以外の featured-*.jpg を削除する。
    private static func cleanup(keeping keepName: String, in container: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: container.path) else { return }
        for f in files where f.hasPrefix("featured-") && f.hasSuffix(".jpg") && f != keepName {
            try? fm.removeItem(at: container.appendingPathComponent(f))
        }
    }

    /// FNV-1a 32bit。ファイル名用の安定ハッシュ（Hasher は実行ごとに変わるため使わない）。
    private static func stableHash(_ s: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(hash, radix: 16)
    }
}
