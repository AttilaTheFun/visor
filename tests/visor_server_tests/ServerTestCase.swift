import XCTest

/// A test of the server: the platform it asks of the system is installed
/// before each test runs, ahead of its setUp (TestPlatform — the build's
/// own: a Mac's under Bazel, Linux's under SwiftPM there). On the main
/// actor, as the server is.
@MainActor
class ServerTestCase: XCTestCase {
    nonisolated override func invokeTest() {
        TestPlatform.install()
        super.invokeTest()
    }
}
