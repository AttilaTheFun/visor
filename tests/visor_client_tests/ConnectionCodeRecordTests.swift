// A computer added by its code — pasted, scanned or opened as a link —
// keeps the code's id and every path, and its sign-in when the code says
// none; and one known only over SSH, on a device without SSH, says so
// rather than trying its SSH address as a URL.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class ConnectionCodeRecordTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        ScriptedProvider.server = ScriptedServer()
        ScriptedProvider.servers = [:]
        VisorHost.settings = MemorySettings()
        VisorHost.ssh = nil
    }

    private let sshFirst = ConnectionCode(name: "MacBook", host: "ssh://logan@100.73.57.115", password: "pw", id: "mb",
                                          paths: ["http://100.73.57.115:7433"])

    func testARecordFromACodeKeepsItsIdAndPaths() {
        let record = AgentServerRecord(code: sshFirst)
        XCTAssertEqual(record.address, "ssh://logan@100.73.57.115")
        XCTAssertEqual(record.serverID, "mb")
        XCTAssertEqual(record.paths, ["http://100.73.57.115:7433"])
        XCTAssertEqual(record.authentication, "", "the code named none")
        // A device without SSH takes the other path.
        XCTAssertEqual(AgentServerConnection(record: record).pathsToTry(), ["http://100.73.57.115:7433"])
    }

    /// Added through the form (store.add) as through a link: a code that
    /// names no sign-in leaves a held computer's, and a new one gets the
    /// password.
    func testACodeWithoutASignInLeavesAHeldOnesSignIn() {
        let store = VisorStore()
        let added = store.add(AgentServerRecord(code: sshFirst))
        XCTAssertEqual(added.record.authentication, PasswordAuthenticator.name)
        added.update { $0.authentication = NoAuthenticator.name }
        _ = store.add(AgentServerRecord(code: sshFirst))
        XCTAssertEqual(added.record.authentication, NoAuthenticator.name)
        XCTAssertEqual(store.servers.count, 1)
    }

    /// Known only over SSH, with no SSH here: no path, and a plain failure.
    func testAComputerKnownOnlyOverSSHSaysSoWithoutSSH() async {
        let record = AgentServerRecord(name: "MacBook", address: "ssh://logan@100.73.57.115", secret: "pw", provider: "scripted")
        let server = ScriptedServer()
        ScriptedProvider.servers[record.id] = server
        AgentServerProviders.register(ScriptedProvider())
        let host = AgentServerConnection(record: record)
        XCTAssertEqual(host.pathsToTry(), [])
        host.connect()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(server.signedInBy.isEmpty, "nothing tried")
        if case .failed(let message) = host.state {
            XCTAssertTrue(message.contains("only over SSH"), message)
        } else {
            XCTFail("\(host.state)")
        }
    }
}
