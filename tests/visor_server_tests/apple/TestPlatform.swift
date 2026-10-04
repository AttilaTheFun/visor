import Foundation
import VisorServer
import VisorServerApple

/// A Mac's platform for the tests: secrets in memory, and what the server
/// keeps in a scratch folder rather than the installed server's.
enum TestPlatform {
    static func install() {
        var platform = ServerPlatform.apple(secrets: MemorySecrets())
        platform.host = HostDetails(name: "Test Mac", dataDirectory: scratch)
        ServerPlatform.current = platform
    }

    private static let scratch: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
}
