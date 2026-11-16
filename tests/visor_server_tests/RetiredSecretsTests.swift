// A secret nothing reads any more is deleted when the server loads: the
// GitHub proxy's token, left behind by a build before its setup was
// removed (visor#422). The secrets still in use stay.

import Foundation
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class RetiredSecretsTests {
    @Test func theGitHubProxysTokenIsDeletedAtLoad() {
        TestPlatform.install()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-retired-secrets-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        let secrets = MemorySecrets()
        secrets.set("github.proxyToken", "left-behind")
        secrets.set("password", "pw")
        VisorServer.secrets = secrets
        let server = VisorServer(port: ServerTestCase.freePort())
        #expect(secrets.get("github.proxyToken") == nil)
        #expect(secrets.get("password") == "pw")
        #expect(server.password == "pw")
        server.stop()
    }
}
}
