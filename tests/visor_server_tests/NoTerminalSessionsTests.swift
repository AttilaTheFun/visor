// There are no terminal sessions now (0.18 to 0.31 had them, agent
// "shell"): what an older build kept, sends or lists of them is dropped
// or ignored, never taken for a Claude session.

import Foundation
import VisorProtocol
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor final class NoTerminalSessionsTests {
    private var root: URL!

    init() async throws {
        TestPlatform.install()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-no-terminals-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
    }

    /// One kept by an older server is dropped at load, and the file is
    /// written again without it; the chats beside it come back as they
    /// were.
    @Test func testAStoredTerminalSessionIsDroppedAtLoad() throws {
        let file = """
            [{"info":{"id":"T","agent":"shell","cwd":"/tmp","title":"Terminal 1","created":1,"mode":{"kind":"tui","controller":"phone","cols":80,"rows":24}},"entries":[]},
             {"info":{"id":"C","agent":"claude","cwd":"/tmp","title":"Chat","created":2},"entries":[]}]
            """
        try Data(file.utf8).write(to: root.appendingPathComponent("sessions.json"))
        let server = VisorServer(port: 7995)
        defer { server.stop() }
        #expect(server.sessions.map(\.info.id) == ["C"])
        #expect((server.sessions.first?.info.agent) == .claude)
        #expect(server.storeIsReadable)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("sessions.json"))) as? [[String: Any]]
        #expect((written?.compactMap { ($0["info"] as? [String: Any])?["id"] as? String }) == ["C"])
    }

    /// An older client's terminal is not started, and what it says to one
    /// changes nothing.
    @Test func testAnOlderClientsTerminalIsNotStarted() throws {
        let server = VisorServer(port: 7995)
        defer { server.stop() }
        let start = try #require(Envelope.decode(#"{"type":"start","id":"T","agent":"shell","cwd":"/tmp","title":""}"#))
        server.perform(start, from: nil)
        #expect(server.session("T") == nil)
        for said in [#"{"type":"mode","session":"T","mode":"tui","cols":80,"rows":24}"#, #"{"type":"input","session":"T","data":"bHMK"}"#,
                     #"{"type":"resize","session":"T","cols":100,"rows":30}"#] {
            server.perform(try #require(Envelope.decode(said)), from: nil)
        }
        #expect(server.sessions.isEmpty)
    }

    /// An older server's list, read by a client: its terminal is left out,
    /// and so is the kind in its catalogs.
    @Test func testAnOlderServersTerminalIsNotListed() throws {
        let welcome = """
            {"type":"welcome","host":"Mac","sessions":[{"id":"T","agent":"shell","cwd":"/tmp","title":"Terminal 1",\
            "mode":{"kind":"tui","controller":"phone","cols":80,"rows":24}},{"id":"C","agent":"claude","cwd":"/tmp","title":"Chat"}],\
            "catalogs":[{"agent":"claude","models":[]},{"agent":"shell","models":[]}]}
            """
        let decoded = try #require(Envelope.decode(welcome))
        #expect((decoded.sessions?.map(\.id)) == ["C"])
        #expect((decoded.catalogs?.map(\.agent)) == [.claude])
    }
}
}
