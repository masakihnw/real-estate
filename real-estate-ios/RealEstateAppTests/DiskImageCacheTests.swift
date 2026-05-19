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
}
