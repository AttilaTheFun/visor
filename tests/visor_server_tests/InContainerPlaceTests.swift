// A server that runs in a container itself (a co-tenant container) says so
// of every session: the client marks them with the container's box rather
// than the penguin.

import Foundation
@testable import VisorAgent
import VisorProtocol
@testable import VisorServer
import VisorSystem
import XCTest

@MainActor
final class InContainerPlaceTests: ServerTestCase {
    private var host: HostDetails!

    override func setUp() async throws {
        host = ServerPlatform.current.host
    }

    override func tearDown() async throws {
        ServerPlatform.current.host = host
    }

    private func record() -> SessionRecord {
        let info = SessionInfo(id: "S", agent: .claude, cwd: "/root/work", title: "S", created: 0)
        return SessionRecord(info: info, process: ClaudeProcess(cwd: "/root/work", skipPermissions: true, resume: nil))
    }

    func testAServerInAContainerSaysSoOfItsSessions() throws {
        ServerPlatform.current.host = HostDetails(name: "co-tenant", system: "linux", inContainer: true,
                                                  dataDirectory: FileManager.default.temporaryDirectory)
        let session = record()
        XCTAssertEqual(session.info.inContainer, true)
        XCTAssertEqual(session.info.system, "linux")
        let read = try XCTUnwrap(SessionInfo(json: session.info.json))
        XCTAssertEqual(read.inContainer, true, "as a client reads it")
    }

    func testAServerOnAComputerSaysNothing() throws {
        ServerPlatform.current.host = HostDetails(name: "Studio Mac", system: "macos", dataDirectory: FileManager.default.temporaryDirectory)
        let session = record()
        XCTAssertNil(session.info.inContainer)
        XCTAssertNil(session.info.json["inContainer"].bool, "not written at all")
    }
}
