// A session moved to a runner, made ready before it starts: its
// conversation fetched from the driver into the harness's folder (pieces
// joined, nothing overwritten, nothing outside it), its repositories
// cloned by name and ref (one already there left), and the job's keys and
// the runner's folders read.

import AgentProtocol
@testable import AgentWrapper
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import XCTest

final class ResumeTests: XCTestCase {
    private func folder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: made) }
        return made
    }

    func testTheConversationComesFromTheDriverIntoTheHarnessesFolder() async throws {
        let claude = try folder()
        let transport = HTTP2ServerTransport.Posix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext)
        try await withGRPCServer(transport: transport, services: [TestDriver()]) { server in
            let address = try await transport.listeningAddress
            let port = try XCTUnwrap(address.ipv4?.port)
            var agent = AgentProtocol_V1_AgentID()
            agent.uuid = "a3"
            let written = try await ResumePreparation.fetchConversation(
                driverURL: "http://127.0.0.1:\(port)", agent: agent, workingDirectory: "/work", harness: "claude", into: claude)
            XCTAssertEqual(written, 2)
            let conversation = try String(contentsOf: claude.appendingPathComponent("projects/-work/s1.jsonl"), encoding: .utf8)
            XCTAssertEqual(conversation, "{\"a\":1}\n{\"b\":2}\n", "its pieces joined, in order")
            XCTAssertEqual(try String(contentsOf: claude.appendingPathComponent("projects/-work/memory/MEMORY.md"), encoding: .utf8),
                           "- a memory\n")
            let again = try await ResumePreparation.fetchConversation(
                driverURL: "http://127.0.0.1:\(port)", agent: agent, workingDirectory: "/work", harness: "claude", into: claude)
            XCTAssertEqual(again, 0, "what is there already is left as it is")
            var stranger = AgentProtocol_V1_AgentID()
            stranger.uuid = "nobody"
            let none = try await ResumePreparation.fetchConversation(
                driverURL: "http://127.0.0.1:\(port)", agent: stranger, workingDirectory: "/work", harness: "claude", into: claude)
            XCTAssertEqual(none, 0)
            server.beginGracefulShutdown()
        }
    }

    func testAPlaceOutsideTheHarnessesFolderIsRefused() throws {
        var writer = ConversationWriter(folder: try folder())
        for place in ["../escape", "/etc/passwd", "projects/./x", ""] {
            XCTAssertThrowsError(try writer.take(.with { $0.place = place; $0.data = Data("x".utf8); $0.last = true }), place)
        }
        XCTAssertEqual(writer.written, 0)
    }

    func testSourcesAreClonedByNameAndRefOnce() throws {
        let sources = try folder()
        try FileManager.default.createDirectory(at: sources.appendingPathComponent("visor"), withIntermediateDirectories: true)
        var calls: [[String]] = []
        let cloned = try ResumePreparation.clone([
            .with { $0.repository = "https://github.com/AttilaTheFun/visor.git"; $0.ref = "main" },
            .with { $0.repository = "https://github.com/AttilaTheFun/isomer.git"; $0.ref = "fix-1" },
            .with { $0.repository = "https://github.com/AttilaTheFun/agent_ui.git"; $0.name = "ui" },
            .with { $0.repository = "https://github.com/AttilaTheFun/evil.git"; $0.name = "../out" },
        ], into: sources.path) { arguments in
            calls.append(arguments)
            return 0
        }
        XCTAssertEqual(calls, [
            ["clone", "--quiet", "--branch", "fix-1", "https://github.com/AttilaTheFun/isomer.git", sources.appendingPathComponent("isomer").path],
            ["clone", "--quiet", "https://github.com/AttilaTheFun/agent_ui.git", sources.appendingPathComponent("ui").path],
        ], "visor is there already; a name with a slash is no folder's")
        XCTAssertEqual(cloned.count, 2)
        XCTAssertThrowsError(try ResumePreparation.clone([.with { $0.repository = "https://x/y.git" }], into: sources.path) { _ in 128 })
    }

    func testTheJobsResumeAndSourcesAndTheRunnersFolders() throws {
        let job = """
            {"agent": "s9", "dispatcherURL": "http://d", "title": "Moved", "resumeSessionID": "c-123",
             "sources": [{"repository": "https://github.com/AttilaTheFun/visor.git", "ref": "main", "name": "visor"}]}
            """
        let options = try WrapperOptions(arguments: [], environment: [
            "AGENT_JOB": job, "AGENT_SESSIONS_DIR": "/Volumes/Sessions", "AGENT_SOURCES_DIR": "/Volumes/Sources",
        ])
        XCTAssertEqual(options.spec.resumeSessionID, "c-123")
        XCTAssertEqual(options.sources.map(\.name), ["visor"])
        XCTAssertEqual(options.sources.first?.ref, "main")
        XCTAssertEqual(options.sourcesDirectory, "/Volumes/Sources")
        XCTAssertEqual(options.spec.workingDirectory, "/Volumes/Sessions/Claude/s9", "a folder of its own where sessions are kept")
        let named = try WrapperOptions(arguments: [], environment: [
            "AGENT_JOB": #"{"agent": "s9", "dispatcherURL": "http://d", "workingDirectory": "/w"}"#, "AGENT_SESSIONS_DIR": "/Volumes/Sessions",
        ])
        XCTAssertEqual(named.spec.workingDirectory, "/w", "a folder the job names stays")
    }
}
