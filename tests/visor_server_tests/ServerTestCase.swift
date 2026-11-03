#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
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

    /// A loopback port nothing listens on now, the system's choice: for a
    /// test's server that listens, so that runs side by side on one
    /// computer (CI's slots on the primary Mac) don't take each other's.
    /// 0, the system's choice again, should none be had.
    nonisolated static func freePort() -> UInt16 {
        #if canImport(Glibc)
        let probe = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard probe >= 0 else { return 0 }
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, length) == 0 && getsockname(probe, $0, &length) == 0 }
        }
        return found ? UInt16(bigEndian: address.sin_port) : 0
    }
}
