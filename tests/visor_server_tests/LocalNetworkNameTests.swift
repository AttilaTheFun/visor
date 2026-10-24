// A computer's name on its local network (`<name>.local`) is among the
// paths a client is given while the LAN is on, beside its addresses: when
// the network gives the computer another address, a device at home still
// reaches it by name.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class LocalNetworkNameTests: ServerTestCase {
    private var server: VisorServer!
    private var host: HostDetails!

    override func setUp() async throws {
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-local-name-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        host = ServerPlatform.current.host
        ServerPlatform.current.host = HostDetails(name: "Studio Mac", dataDirectory: root,
                                                  networkAddresses: { [NetworkAddress(address: "192.168.1.20", interface: "en0")] },
                                                  localNetworkName: { "Studio-Mac.local" })
        server = VisorServer(port: 7998)
    }

    override func tearDown() async throws {
        server.stop()
        ServerPlatform.current.host = host
    }

    func testTheNameIsAPathWhileTheLANIsOn() {
        server.settings.lan = true
        XCTAssertEqual(server.httpPaths, ["http://192.168.1.20:7998", "http://Studio-Mac.local:7998"])
        server.settings.lan = false
        XCTAssertFalse(server.httpPaths.contains { $0.contains("Studio-Mac.local") })
    }

    func testSSHReachesTheNameToo() {
        server.settings.sshEnabled = true
        let user = NSUserName()
        XCTAssertEqual(server.sshPaths, ["ssh://\(user)@192.168.1.20", "ssh://\(user)@Studio-Mac.local"])
    }

    func testAComputerWithNoNameGivesOnlyItsAddresses() {
        ServerPlatform.current.host.localNetworkName = { nil }
        server.settings.lan = true
        XCTAssertEqual(server.httpPaths, ["http://192.168.1.20:7998"])
    }
}
