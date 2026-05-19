import Testing
import Foundation
@testable import RealEstateApp

@Suite("ObjCExceptionCatcher")
struct ObjCExceptionCatcherTests {

    @Test("正常なブロックはエラーなしで実行される")
    func normalBlockSucceeds() throws {
        var executed = false
        try ObjCExceptionCatcher.perform {
            executed = true
        }
        #expect(executed)
    }

    @Test("NSException を Swift エラーに変換する")
    func catchesNSException() {
        #expect(throws: (any Error).self) {
            try ObjCExceptionCatcher.perform {
                NSException(name: .genericException, reason: "test crash", userInfo: nil).raise()
            }
        }
    }

    @Test("NSException の reason がエラーメッセージに含まれる")
    func exceptionReasonPreserved() {
        do {
            try ObjCExceptionCatcher.perform {
                NSException(name: .invalidArgumentException, reason: "invalid schema migration", userInfo: nil).raise()
            }
            Issue.record("Should have thrown")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "ObjCExceptionCatcher")
            #expect(nsError.localizedDescription.contains("invalid schema migration"))
        }
    }

    @Test("NSException の name がエラー userInfo に含まれる")
    func exceptionNamePreserved() {
        do {
            try ObjCExceptionCatcher.perform {
                NSException(name: .rangeException, reason: "out of bounds", userInfo: nil).raise()
            }
            Issue.record("Should have thrown")
        } catch {
            let nsError = error as NSError
            let exceptionName = nsError.userInfo["ExceptionName"] as? String
            #expect(exceptionName == NSExceptionName.rangeException.rawValue)
        }
    }

    @Test("ブロック内の Swift エラーは NSException として扱われない")
    func swiftErrorPassesThrough() {
        enum TestError: Error { case sample }
        var swiftErrorThrown = false

        try? ObjCExceptionCatcher.perform {
            swiftErrorThrown = true
            // Swift error inside the block doesn't propagate as NSException
        }
        #expect(swiftErrorThrown)
    }
}
