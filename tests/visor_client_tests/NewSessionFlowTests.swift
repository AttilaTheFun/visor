// A server that sets its sessions up its own way: named choices in place
// of folders, sessions that start with their first message, and — where it
// keeps no titles, archive or ending of its own — renaming, archiving and
// removing kept on this device, by record.

import Foundation
@testable import VisorClient
import VisorProtocol
import VisorServices
import XCTest

@MainActor
final class NewSessionFlowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AgentServerConnection.cache = .inMemory()
        ScriptedProvider.server = ScriptedServer()
        ScriptedProvider.servers = [:]
        AgentServerProviders.register(ScriptedProvider())
        VisorHost.settings = MemorySettings()
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    private let record = AgentServerRecord(name: "Hosted", address: "https://agents.example.com", secret: "", provider: "scripted")

    private func connected(_ server: ScriptedServer) async -> AgentServerConnection {
        ScriptedProvider.servers[record.id] = server
        let host = AgentServerConnection(record: record)
        host.connect()
        for _ in 0..<5 { await settle() }
        return host
    }

    private func session(_ id: String, title: String = "Run", archived: Bool = false) -> SessionInfo {
        SessionInfo(id: id, agent: .claude, cwd: "tmpl-web", title: title, archived: archived, created: 0)
    }

    /// The server's choices are asked for once it connects, and a session
    /// started from one is grouped under it, by its title.
    func testChoicesInPlaceOfFolders() async throws {
        let server = ScriptedServer()
        server.starting = SessionStarting(fromChoices: true)
        server.choices = [StartChoice(id: "tmpl-web", title: "Web app"), StartChoice(id: "tmpl-cli", title: "Command line")]
        let host = await connected(server)
        XCTAssertEqual(host.startChoices.map(\.id), ["tmpl-web", "tmpl-cli"])
        let id = try await host.start(agent: .claude, cwd: "tmpl-web", title: "", skipPermissions: true)
        XCTAssertEqual(server.started.map(\.cwd), ["tmpl-web"])
        XCTAssertEqual(host.projects.first { $0.cwd == "tmpl-web" }?.name, "Web app")
        XCTAssertTrue(host.sessions.contains { $0.id == id })
    }

    /// A session that starts with its first message: started, then sent it,
    /// by default.
    func testAFirstMessageStartsTheSession() async throws {
        let server = ScriptedServer()
        server.starting = SessionStarting(withFirstMessage: true)
        let host = await connected(server)
        let id = try await host.start(agent: .claude, cwd: "~", title: "", skipPermissions: true, firstMessage: "Fix the build")
        XCTAssertEqual(server.started.map(\.id), [id])
        XCTAssertEqual(server.sent.map(\.1), ["Fix the build"])
        XCTAssertEqual(server.subscribed, [id])
    }

    /// Renamed, archived and removed here, for a server that keeps none of
    /// it: nothing asked of the server, laid over every list it sends, and
    /// kept for the record.
    func testRenamingAndArchivingAreKeptHereForAServerWithout() async {
        let server = ScriptedServer()
        server.managesSessions = false
        let host = await connected(server)
        server.deliver(.sessions([session("a"), session("b"), session("c")]))
        host.rename("a", title: "Login page")
        host.archive("b")
        host.end("c")
        XCTAssertTrue(server.actions.isEmpty, "nothing asked of the server")
        XCTAssertEqual(host.sessions.map(\.id), ["a", "b"])
        XCTAssertEqual(host.sessions.first?.title, "Login page")
        XCTAssertEqual(host.archivedSessions.map(\.id), ["b"])

        // The server's next list says nothing of it; the edits stand.
        server.deliver(.sessions([session("a"), session("b"), session("c"), session("d")]))
        XCTAssertEqual(host.sessions.map(\.id), ["a", "b", "d"])
        XCTAssertEqual(host.sessions.first?.title, "Login page")
        host.unarchive("b")
        XCTAssertEqual(host.archivedSessions, [])

        // Kept for the record: a new connection to it has them.
        host.disconnect()
        let again = await connected(server)
        server.deliver(.sessions([session("a"), session("b"), session("c")]))
        XCTAssertEqual(again.sessions.map(\.title), ["Login page", "Run"])
    }

    /// A server that keeps them itself is asked, as before.
    func testAServerThatKeepsThemIsAsked() async {
        let server = ScriptedServer()
        let host = await connected(server)
        server.deliver(.sessions([session("a")]))
        host.rename("a", title: "New")
        host.archive("a")
        for _ in 0..<3 { await settle() }
        XCTAssertEqual(server.actions.map(\.0), [.rename(title: "New"), .archive])
    }
}
