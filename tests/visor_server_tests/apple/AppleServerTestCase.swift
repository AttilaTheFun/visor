import XCTest

/// A test of the server's Apple system, in XCTest: these run by hand on a
/// Mac, in an .xctest bundle (`xcrun xctest` runs XCTest's alone), where
/// the rest run on Linux in Swift Testing. The platform it asks of the
/// system is installed before each test, ahead of its setUp. On the main
/// actor, as the server is.
@MainActor
class AppleServerTestCase: XCTestCase {
    nonisolated override func invokeTest() {
        TestPlatform.install()
        super.invokeTest()
    }
}
