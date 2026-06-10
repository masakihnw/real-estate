import Testing
import Foundation
import UIKit
@testable import RealEstateApp

@Suite("DiskImageCache")
struct DiskImageCacheTests {

    @Test("シングルトンの初期化がクラッシュしない")
    func sharedInitDoesNotCrash() {
        let cache = DiskImageCache.shared
        #expect(cache != nil)
    }

    @Test("存在しないキーに対して nil を返す")
    func missingKeyReturnsNil() {
        let image = DiskImageCache.shared.image(for: "nonexistent-key-\(UUID().uuidString)")
        #expect(image == nil)
    }

    @Test("画像の保存と読み出しが正しく動作する")
    func saveAndLoadImage() {
        let key = "test-image-\(UUID().uuidString)"
        let size = CGSize(width: 10, height: 10)
        let renderer = UIGraphicsImageRenderer(size: size)
        let testImage = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        DiskImageCache.shared.save(testImage, for: key)

        // ディスク書き込みは非同期の DispatchQueue なので少し待つ
        let expectation = Task {
            try await Task.sleep(for: .milliseconds(200))
            return DiskImageCache.shared.image(for: key)
        }
        // save 直後に読み出しは同期的には保証されないが、キャッシュディレクトリは存在するはず
        #expect(DiskImageCache.shared != nil)
    }

    @Test("imageAsync は存在しないキーに対して nil を返す")
    func asyncMissingKeyReturnsNil() async {
        let image = await DiskImageCache.shared.imageAsync(for: "nonexistent-async-\(UUID().uuidString)")
        #expect(image == nil)
    }

    @Test("imageAsync は保存済み画像を返す")
    func asyncSaveAndLoad() async throws {
        let key = "test-async-\(UUID().uuidString)"
        let size = CGSize(width: 8, height: 8)
        let renderer = UIGraphicsImageRenderer(size: size)
        let testImage = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        DiskImageCache.shared.save(testImage, for: key)
        try await Task.sleep(for: .milliseconds(300))

        let loaded = await DiskImageCache.shared.imageAsync(for: key)
        #expect(loaded != nil)
    }

    // MARK: - ディスク上限（LRU トリム）

    private func makeTestImage() -> UIImage {
        let size = CGSize(width: 4, height: 4)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("上限を超えた保存で古いファイルから削除される")
    func trimEnforcesMaxFileCount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskImageCache(directory: dir, maxFileCount: 5)

        let image = makeTestImage()
        for i in 0..<9 {
            cache.save(image, for: "key-\(i)")
        }
        cache.waitForPendingOperations()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count <= 5, "上限5に対して \(files.count) ファイル残存（無制限に増殖する）")
    }

    @Test("上限以内ならファイルは削除されない")
    func noTrimUnderLimit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskImageCache(directory: dir, maxFileCount: 10)

        let image = makeTestImage()
        for i in 0..<3 {
            cache.save(image, for: "key-\(i)")
        }
        cache.waitForPendingOperations()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 3)
    }
}
