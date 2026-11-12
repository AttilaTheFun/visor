// A computer's name on its local network (`<name>.local`) is among the
// paths a client is given while the LAN is on, beside its addresses: when
// the network gives the computer another address, a device at home still
// reaches it by name.

import Foundation
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class LocalNetworkNameTests {
    private var server: VisorServer!
    private var host: HostDetails!

    init() async throws {
        TestPlatform.install()
        // Never the real archive: loading it ends the agents it lists.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-local-name-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        host = ServerPlatform.current.host
        ServerPlatform.current.host = HostDetails(name: "Studio Mac", dataDirectory: root,
                                                  networkAddresses: { [NetworkAddress(address: "192.168.1.20", interface: "en0")] },
                                                  localNetworkName: { "Studio-Mac.local" })
        server = VisorServer(port: ServerTestCase.freePort())
    }

    isolated deinit {
        server.stop()
        ServerPlatform.current.host = host
    }

    @Test func testTheNameIsAPathWhileTheLANIsOn() {
        server.settings.lan = true
        #expect(server.httpPaths == ["http://192.168.1.20:\(server.port)", "http://Studio-Mac.local:\(server.port)", "http://127.0.0.1:\(server.port)"])
        server.settings.lan = false
        #expect(!(server.httpPaths.contains { $0.contains("Studio-Mac.local") }))
    }

    @Test func testSSHReachesTheNameToo() {
        server.settings.sshEnabled = true
        let user = NSUserName()
        #expect(server.sshPaths == ["ssh://\(user)@192.168.1.20", "ssh://\(user)@Studio-Mac.local"])
    }

    /// A server behind a front (in a container, behind Visor Runner)
    /// gives the front's paths, not its own: the code's address is the
    /// first another device reaches, never loopback.
    @Test func testAServerBehindAFrontGivesTheFrontsPaths() throws {
        server.password = "pw"
        server.settings.lan = true
        server.settings.frontPaths = ["http://127.0.0.1:7440", "http://192.168.1.20:7440", "http://100.64.0.11:7440"]
        #expect(server.ownAddresses == server.settings.frontPaths)
        #expect(server.reachableAddress == "http://192.168.1.20:7440")
        let code = try #require(server.connectionCode)
        #expect(code.host == "http://192.168.1.20:7440")
        #expect(!(code.paths.contains("http://192.168.1.20:\(server.port)")), "not the container's own")
        #expect(code.paths.contains("http://127.0.0.1:7440"))
        server.settings.frontPaths = []
        #expect(server.reachableAddress == "http://192.168.1.20:\(server.port)")
    }

    @Test func testAComputerWithNoNameGivesOnlyItsAddresses() {
        ServerPlatform.current.host.localNetworkName = { nil }
        server.settings.lan = true
        #expect(server.httpPaths == ["http://192.168.1.20:\(server.port)", "http://127.0.0.1:\(server.port)"])
    }

    /// A bridge to the computer's own containers or VMs is none of the
    /// addresses a server gives: it is the same address on every computer.
    @Test func testABridgeIsNotOneOfTheServersAddresses() {
        for bridge in ["bridge100", "bridge0", "docker0", "br-1a2b3c", "virbr0", "cni0", "lxcbr0"] {
            #expect(NetworkInterfaces.isBridge(bridge), Comment(rawValue: bridge))
        }
        for network in ["en0", "en1", "utun4", "eth0", "wlan0", "tailscale0"] {
            #expect(!NetworkInterfaces.isBridge(network), Comment(rawValue: network))
        }
    }
}
}
