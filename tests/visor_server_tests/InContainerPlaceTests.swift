// A server that runs in a container itself (a co-tenant container) says so
// of every session: the client marks them with the container's box rather
// than the penguin.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import Testing

extension ServerTests {
@Suite @MainActor final class InContainerPlaceTests {
    private var host: HostDetails!

    init() async throws {
        TestPlatform.install()
        host = ServerPlatform.current.host
    }

    isolated deinit {
        ServerPlatform.current.host = host
    }

    private func record() -> SessionRecord {
        let info = SessionInfo(id: "S", agent: .claude, cwd: "/root/work", title: "S", created: 0)
        return SessionRecord(info: info, process: ClaudeProcess(cwd: "/root/work", skipPermissions: true, resume: nil))
    }

    @Test func testAServerInAContainerSaysSoOfItsSessions() throws {
        ServerPlatform.current.host = HostDetails(name: "co-tenant", system: "linux", inContainer: true,
                                                  dataDirectory: FileManager.default.temporaryDirectory)
        let session = record()
        #expect(session.info.inContainer == true)
        #expect(session.info.system == "linux")
        let read = try #require(SessionInfo(json: session.info.json))
        #expect(read.inContainer == true, "as a client reads it")
    }

    @Test func testAServerOnAComputerSaysNothing() throws {
        ServerPlatform.current.host = HostDetails(name: "Studio Mac", system: "macos", dataDirectory: FileManager.default.temporaryDirectory)
        let session = record()
        #expect(session.info.inContainer == nil)
        #expect((session.info.json["inContainer"].bool) == nil, "not written at all")
    }
}
}
