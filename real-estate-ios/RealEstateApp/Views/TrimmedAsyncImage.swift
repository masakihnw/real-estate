import SwiftUI
import UIKit

// MARK: - ディスク画像キャッシュ

/// トリミング済み画像を Caches/ImageCache に保存するシングルトン。メモリキャッシュのフォールバックとして使用。
final class DiskImageCache: @unchecked Sendable {
    static let shared = DiskImageCache()
    private let cacheDir: URL
    private let queue = DispatchQueue(label: "diskImageCache", qos: .utility)

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func path(for key: String) -> URL {
        let hash = key.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined()
        let shortHash = String(hash.prefix(40))
        return cacheDir.appendingPathComponent(shortHash + ".jpg")
    }

    func image(for key: String) -> UIImage? {
        let url = path(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func save(_ image: UIImage, for key: String) {
        queue.async { [self] in
            let url = path(for: key)
            if let data = image.jpegData(compressionQuality: 0.85) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func clearAll() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - トリミング済み画像キャッシュ

/// 余白トリミング済み画像を NSCache で保持するシングルトン
final class TrimmedImageCache: @unchecked Sendable {
    static let shared = TrimmedImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 200
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

// MARK: - TrimmedAsyncImage

/// URL から画像を非同期読み込みし、周囲の白余白を自動トリミングして表示するビュー。
/// SUUMO 画像など元画像にパディングが含まれるケースに対応。
struct TrimmedAsyncImage: View {
    let url: URL
    let width: CGFloat
    /// 固定高さ。省略時は `width * 0.75`
    var height: CGFloat?

    private var resolvedHeight: CGFloat { height ?? width * 0.75 }

    @State private var loadedImage: UIImage?
    @State private var loadPhase: Phase = .loading

    private enum Phase { case loading, success, failure }

    var body: some View {
        Group {
            switch loadPhase {
            case .success:
                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: resolvedHeight)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            case .failure:
                placeholder(icon: "building.2")
            case .loading:
                ZStack {
                    Color(.systemGray6)
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(width: width, height: resolvedHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: url) {
            await loadAndTrim()
        }
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            Color(.systemGray6)
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.quaternary)
        }
        .frame(width: width, height: resolvedHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadAndTrim() async {
        let cacheKey = url.absoluteString

        // 1. メモリキャッシュ
        if let cached = TrimmedImageCache.shared.image(for: cacheKey) {
            loadedImage = cached
            loadPhase = .success
            return
        }

        // 2. ディスクキャッシュ
        if let diskCached = DiskImageCache.shared.image(for: cacheKey) {
            TrimmedImageCache.shared.set(diskCached, for: cacheKey)
            loadedImage = diskCached
            loadPhase = .success
            return
        }

        // 3. ネットワーク取得
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let original = UIImage(data: data) else {
                loadPhase = .failure
                return
            }
            let trimmed = original.trimmingWhitespaceBorder()
            TrimmedImageCache.shared.set(trimmed, for: cacheKey)
            DiskImageCache.shared.save(trimmed, for: cacheKey)
            loadedImage = trimmed
            loadPhase = .success
        } catch {
            loadPhase = .failure
        }
    }
}

// MARK: - UIImage 余白トリミング

extension UIImage {
    /// 画像の四辺から白（近白色）ピクセルの余白を検出してトリミングする。
    /// - Parameter tolerance: 白と見なす閾値（0.0〜1.0）。デフォルト 0.93 ≒ RGB 各 237/255 以上。
    /// - Returns: トリミング済み UIImage。余白がない場合やトリミング不要な場合はそのまま返す。
    func trimmingWhitespaceBorder(tolerance: CGFloat = 0.93) -> UIImage {
        guard let cgImage = self.cgImage else { return self }

        let w = cgImage.width
        let h = cgImage.height
        guard w > 8, h > 8 else { return self }

        // 既知の RGBA 8-bit フォーマットに描画して一貫したピクセルアクセスを保証
        let bpp = 4
        let bpr = bpp * w
        var pixels = [UInt8](repeating: 255, count: h * bpr)

        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return self }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let thresh = UInt8(tolerance * 255)

        // ピクセルが白系か判定（透明ピクセルも余白扱い）
        func isWhitish(_ offset: Int) -> Bool {
            let a = pixels[offset + 3]
            if a < 10 { return true }
            return pixels[offset] >= thresh
                && pixels[offset + 1] >= thresh
                && pixels[offset + 2] >= thresh
        }

        // 走査ステップ（パフォーマンス最適化: 全ピクセルではなくサンプリング）
        let step = max(1, min(w, h) / 120)

        var top = 0
        var bottom = h - 1
        var left = 0
        var right = w - 1

        // 上辺から走査
        topScan: for y in 0..<h {
            for x in stride(from: 0, to: w, by: step) {
                if !isWhitish(y * bpr + x * bpp) { top = y; break topScan }
            }
            if y == h - 1 { return self } // 全面白 → トリミング不要
        }

        // 下辺から走査
        bottomScan: for y in stride(from: h - 1, through: top, by: -1) {
            for x in stride(from: 0, to: w, by: step) {
                if !isWhitish(y * bpr + x * bpp) { bottom = y; break bottomScan }
            }
        }

        // 左辺から走査
        leftScan: for x in 0..<w {
            for y in stride(from: top, through: bottom, by: step) {
                if !isWhitish(y * bpr + x * bpp) { left = x; break leftScan }
            }
        }

        // 右辺から走査
        rightScan: for x in stride(from: w - 1, through: left, by: -1) {
            for y in stride(from: top, through: bottom, by: step) {
                if !isWhitish(y * bpr + x * bpp) { right = x; break rightScan }
            }
        }

        // 1px のマージンを残す
        top = max(0, top - 1)
        bottom = min(h - 1, bottom + 1)
        left = max(0, left - 1)
        right = min(w - 1, right + 1)

        let cw = right - left + 1
        let ch = bottom - top + 1

        // トリミング結果が小さすぎる場合は元画像を返す（誤検出防止）
        if cw < w / 3 || ch < h / 3 { return self }
        // ほぼ変化なしならそのまま返す
        if cw >= w - 4 && ch >= h - 4 { return self }

        let cropRect = CGRect(x: left, y: top, width: cw, height: ch)
        guard let cropped = cgImage.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}
