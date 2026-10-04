import Foundation
import VisorServer
import VisorServerCLI
import VisorServerLinux

/// Linux's platform for the tests: secrets in memory, and what the server
/// keeps in a scratch folder.
enum TestPlatform {
    static func install() {
        var platform = LinuxSystem().platform(log: { _ in }, lifecycle: TestLifecycle())
        platform.secrets = MemorySecrets()
        platform.host = HostDetails(name: "Test Linux", dataDirectory: scratch)
        ServerPlatform.current = platform
    }

    private static let scratch: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
}

/// A server under test is never relaunched or ended by the tests.
private struct TestLifecycle: ServerLifecycle {
    @MainActor func relaunch(installing build: String?, carrying sessions: String) -> String? { "not in tests" }
    @MainActor func terminate() {}
}
