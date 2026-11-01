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
        XCTAssertEqual(server.httpPaths, ["http://192.168.1.20:7998", "http://Studio-Mac.local:7998", "http://127.0.0.1:7998"])
        server.settings.lan = false
        XCTAssertFalse(server.httpPaths.contains { $0.contains("Studio-Mac.local") })
    }

    func testSSHReachesTheNameToo() {
        server.settings.sshEnabled = true
        let user = NSUserName()
        XCTAssertEqual(server.sshPaths, ["ssh://\(user)@192.168.1.20", "ssh://\(user)@Studio-Mac.local"])
    }

    /// A server behind a front (in a container, behind Visor Runner)
    /// gives the front's paths, not its own: the code's address is the
    /// first another device reaches, never loopback.
    func testAServerBehindAFrontGivesTheFrontsPaths() throws {
        server.password = "pw"
        server.settings.lan = true
        server.settings.frontPaths = ["http://127.0.0.1:7440", "http://192.168.1.20:7440", "http://100.64.0.11:7440"]
        XCTAssertEqual(server.ownAddresses, server.settings.frontPaths)
        XCTAssertEqual(server.reachableAddress, "http://192.168.1.20:7440")
        let code = try XCTUnwrap(server.connectionCode)
        XCTAssertEqual(code.host, "http://192.168.1.20:7440")
        XCTAssertFalse(code.paths.contains("http://192.168.1.20:7998"), "not the container's own")
        XCTAssertTrue(code.paths.contains("http://127.0.0.1:7440"))
        server.settings.frontPaths = []
        XCTAssertEqual(server.reachableAddress, "http://192.168.1.20:7998")
    }

    func testAComputerWithNoNameGivesOnlyItsAddresses() {
        ServerPlatform.current.host.localNetworkName = { nil }
        server.settings.lan = true
        XCTAssertEqual(server.httpPaths, ["http://192.168.1.20:7998", "http://127.0.0.1:7998"])
    }
}
