import UIKit
import OSLog
import CryptoKit

private let logger = Logger(subsystem: "com.realestate", category: "ImagePipeline")

/// 画像の取得・トリミング・キャッシュを一元管理するパイプライン。
/// メモリキャッシュ → ディスクキャッシュ → ネットワーク の3層で解決し、
/// in-flight dedupe により同一URLへの重複リクエストを防止する。
actor ImagePipeline {
    static let shared = ImagePipeline()

    // MARK: - URLSession（タイムアウト・コネクション制限付き）

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    // MARK: - メモリキャッシュ（decoded bytes ベースで制限）
    // NSCache はスレッドセーフだが actor isolation 外からのアクセスに nonisolated(unsafe) が必要
    nonisolated(unsafe) private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 100_000_000 // 100 MB
        cache.countLimit = 200
        return cache
    }()

    // MARK: - In-flight dedupe

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    // MARK: - Public API

    /// 画像を取得してトリミング済みで返す。キャッシュ優先、ネットワークフォールバック。
    func loadTrimmed(from url: URL) async -> UIImage? {
        let key = url.absoluteString

        // 1. メモリキャッシュ
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // 2. 同一URLリクエストのdedupe
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            await self.fetchAndProcess(url: url, key: key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// メモリキャッシュのみ確認（同期的）。プリフェッチ判定用。
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url.absoluteString as NSString)
    }

    /// キャッシュをクリアする。
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    // MARK: - Internal

    private func fetchAndProcess(url: URL, key: String) async -> UIImage? {
        // ディスクキャッシュ
        if let diskCached = await DiskImageCache.shared.imageAsync(for: key) {
            cacheToMemory(diskCached, for: key)
            return diskCached
        }

        // ネットワーク取得（1回リトライ）
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<300).contains(httpResponse.statusCode) {
                    logger.warning("HTTP \(httpResponse.statusCode) for \(url.absoluteString, privacy: .public)")
                    if attempt == 0 { continue }
                    return nil
                }

                guard let original = UIImage(data: data) else {
                    logger.debug("画像デコード失敗: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }

                let trimmed = await Self.trimOffMain(original)
                cacheToMemory(trimmed, for: key)
                DiskImageCache.shared.save(trimmed, for: key)
                return trimmed
            } catch is CancellationError {
                return nil
            } catch {
                if attempt == 0 {
                    logger.debug("リトライ: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                logger.debug("画像取得失敗: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    private func cacheToMemory(_ image: UIImage, for key: String) {
        let cost = imageCost(image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func imageCost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    /// メインスレッドをブロックしないようトリミングをバックグラウンドで実行。
    private static func trimOffMain(_ image: UIImage) async -> UIImage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let trimmed = image.trimmingWhitespaceBorder()
                continuation.resume(returning: trimmed)
            }
        }
    }
}
