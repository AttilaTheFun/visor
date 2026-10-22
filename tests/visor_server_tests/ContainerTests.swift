// Sessions whose agents run in containers on oss: the server makes the
// container (the repository cloned in, Visor's MCP script written into
// it), runs the agent there as a process whose input it writes in order
// and whose output it reads on from where it was left, gives the agent
// Visor's tools and oss's, writes down where it was read to (and no pid of
// this computer's), and says so on the wire. oss is a fake here.

import Foundation
import Synchronization
import VisorProtocol
@testable import VisorServer
import XCTest

/// oss as the server reaches it: what it was asked, and its answers.
final class FakeOSS: HTTPFetching {
    let asked = Mutex<[OutgoingRequest]>([])
    /// The agent's output, and whether it ends once that is read (else it
    /// runs on, saying nothing more).
    let output: Data
    let ends: Bool
    /// What a process writes to its errors, and its exit status.
    let errors: Data
    let status: Int

    init(output: Data = Data(), ends: Bool = true, errors: Data = Data(), status: Int = 0) {
        self.output = output
        self.ends = ends
        self.errors = errors
        self.status = status
    }

    func fetch(_ request: OutgoingRequest) async throws -> OutgoingRequest.Answer {
        asked.withLock { $0.append(request) }
        let path = request.url.replacingOccurrences(of: "http://oss.test:7480", with: "")
        switch (request.method, path) {
        case ("POST", "/v1/agents"):
            return .init(status: 201, body: Data(#"{"id":"c1"}"#.utf8))
        case ("POST", "/v1/agents/c1/processes"):
            return .init(status: 201, body: Data(#"{"id":"p1","pid":42,"state":"running"}"#.utf8))
        case let ("GET", path) where path.hasPrefix("/v1/agents/c1/processes/p1/output?stream=out&from="):
            let from = Int(path.split(separator: "=")[2].split(separator: "&")[0]) ?? 0
            let rest = from < output.count ? output.dropFirst(from) : Data()
            // Held open a moment while there is nothing new, as oss holds it.
            if rest.isEmpty, !ends { try await Task.sleep(for: .milliseconds(50)) }
            return .init(status: 200, body: Data(rest),
                         headers: ["oss-offset": String(output.count), "oss-state": rest.isEmpty && ends ? "exited" : "running", "oss-status": "0"])
        case let ("GET", path) where path.hasPrefix("/v1/agents/c1/processes/p1/output?stream=err&from="):
            let from = Int(path.split(separator: "=")[2].split(separator: "&")[0]) ?? 0
            let rest = from < errors.count ? errors.dropFirst(from) : Data()
            return .init(status: 200, body: Data(rest), headers: ["oss-offset": String(errors.count), "oss-state": "exited", "oss-status": String(status)])
        default:
            return .init(status: 200, body: Data("{}".utf8))
        }
    }

    func requests(_ method: String, containing part: String) -> [OutgoingRequest] {
        asked.withLock { $0.filter { $0.method == method && $0.url.contains(part) } }
    }
}

@MainActor
final class ContainerTests: ServerTestCase {
    private var fetching: (any HTTPFetching)!

    override func setUp() async throws {
        fetching = ServerPlatform.current.fetching
    }

    override func tearDown() async throws {
        ServerPlatform.current.fetching = fetching
    }

    private let client = OSSClient(server: "http://oss.test:7480", token: "secret")

    func testTheAgentsInputGoesInOrderAndItsOutputIsReadToItsEnd() async throws {
        let oss = FakeOSS(output: Data("{\"type\":\"result\"}\n".utf8))
        ServerPlatform.current.fetching = oss
        let child = OSSChild.start(server: client.server, token: { "secret" }, session: "c1", command: ["claude", "-p"],
                                   environment: ["VISOR_SESSION": "s"], directory: "/root/work/visor")
        child.write(["n": 1])
        child.write(["n": 2])
        child.closeInput()
        var heard = Data()
        for await chunk in child.output { heard.append(chunk) }
        XCTAssertEqual(String(decoding: heard, as: UTF8.self), "{\"type\":\"result\"}\n")
        let exit = await child.exit.value
        XCTAssertEqual(exit.status, 0)
        XCTAssertEqual(child.outOffset, heard.count, "where a later server reads on from")
        // Written in order, then the end of input.
        try await Task.sleep(for: .milliseconds(200))
        let inputs = oss.requests("POST", containing: "/input").map { ($0.url.hasSuffix("close=1"), String(decoding: $0.body, as: UTF8.self)) }
        XCTAssertEqual(inputs.map(\.1), ["{\"n\":1}\n", "{\"n\":2}\n", ""])
        XCTAssertEqual(inputs.map(\.0), [false, false, true])
        let started = try XCTUnwrap(oss.requests("POST", containing: "/processes").first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: started.body) as? [String: Any])
        XCTAssertEqual(body["command"] as? [String], ["claude", "-p"])
        XCTAssertEqual(body["directory"] as? String, "/root/work/visor")
        XCTAssertEqual(started.headers["Authorization"], "Bearer secret")
    }

    func testAnAgentInAContainerHasVisorsToolsAndOssesWhereItCanReachThem() throws {
        let placement = ContainerPlacement(server: "http://oss.test:7480", session: "c1", serverURL: "ws://192.168.4.52:7433")
        let config = try XCTUnwrap(VisorMCP.claudeConfig(["VISOR_SESSION": "s", "VISOR_TOKEN": "t"], approvals: true, container: placement))
        let servers = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])?["mcpServers"] as? [String: Any])
        let visor = try XCTUnwrap(servers["visor"] as? [String: Any])
        XCTAssertEqual(visor["command"] as? String, "node")
        XCTAssertEqual(visor["args"] as? [String], [ContainerPlacement.scriptPath])
        XCTAssertEqual((visor["env"] as? [String: String])?["VISOR_URL"], "ws://192.168.4.52:7433")
        let oss = try XCTUnwrap(servers["oss"] as? [String: Any])
        XCTAssertEqual(oss["command"] as? String, "oss")
        XCTAssertEqual(oss["args"] as? [String], ["mcp"])
        let codex = VisorMCP.codexArguments(["VISOR_SESSION": "s"], container: placement)
        XCTAssertTrue(codex.contains("mcp_servers.oss.command=\"oss\""))
        XCTAssertTrue(codex.contains { $0.contains("VISOR_URL=\"ws://192.168.4.52:7433\"") })
    }

    func testASessionStartsInAContainerWithItsRepositoryAndSaysSo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let oss = FakeOSS()
        ServerPlatform.current.fetching = oss
        let server = VisorServer(port: 7997)
        defer { server.stop() }
        XCTAssertFalse(server.containersAvailable)
        server.settings.ossServer = "http://oss.test:7480"
        server.setOSSToken("secret")
        XCTAssertTrue(server.containersAvailable)
        XCTAssertEqual(server.sessionsEnvelope().container, true, "clients are told a session can start in a container")

        let made: SessionRecord = try await withCheckedThrowingContinuation { done in
            server.startInContainer(.startInContainer(id: "s1", agent: .claude, title: "", skipPermissions: true, repository: "AttilaTheFun/visor"),
                                    from: nil) { done.resume(with: $0.mapError { $0 as Error }) }
        }
        XCTAssertEqual(made.info.cwd, "/root/work/visor")
        XCTAssertEqual(made.info.container, SessionContainer(server: "http://oss.test:7480", id: "c1", repository: "AttilaTheFun/visor"))
        XCTAssertEqual(made.info.title, "Claude Code in visor")
        let asked = try XCTUnwrap(oss.requests("POST", containing: "/v1/agents").first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: asked.body) as? [String: Any])
        XCTAssertNil(body["repository"], "cloned by the server, which waits for the clone, not by oss on its own")
        XCTAssertEqual(body["launch"] as? Bool, false)
        let cloned = try XCTUnwrap(oss.requests("POST", containing: "/processes").first)
        let clone = try XCTUnwrap(JSONSerialization.jsonObject(with: cloned.body) as? [String: Any])
        XCTAssertEqual(clone["command"] as? [String], ["git", "clone", "-q", "https://github.com/AttilaTheFun/visor.git", "/root/work/visor"])
        XCTAssertEqual((body["labels"] as? [String: String])?["visor.session"], "s1")
        let script = try XCTUnwrap(oss.requests("PUT", containing: "/files/").first)
        XCTAssertTrue(script.url.hasSuffix("/v1/agents/c1/files/.visor/visor_mcp.js"))
        XCTAssertEqual(String(decoding: script.body, as: UTF8.self), VisorMCPScript.source)
        // Its agent runs there: a pid there is no process of this computer's.
        XCTAssertNotNil((made.process as? HostableProcess)?.container)
        XCTAssertNil(made.stored.agentPID)
    }

    /// A clone that fails says why, and its container goes: no session
    /// is left in an empty folder.
    func testAFailedCloneSaysWhyAndLeavesNoContainer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let oss = FakeOSS(errors: Data("fatal: repository 'https://github.com/o/missing.git/' not found\n".utf8), status: 128)
        ServerPlatform.current.fetching = oss
        let server = VisorServer(port: 7997)
        defer { server.stop() }
        server.settings.ossServer = "http://oss.test:7480"
        server.setOSSToken("secret")
        let ended: Result<SessionRecord, OSSClient.Failure> = await withCheckedContinuation { done in
            server.startInContainer(.startInContainer(id: "s2", agent: .codex, title: "", skipPermissions: true, repository: "o/missing"),
                                    from: nil) { done.resume(returning: $0) }
        }
        guard case .failure(let failure) = ended else { return XCTFail("started all the same") }
        XCTAssertEqual(failure.words, "Cloning https://github.com/o/missing.git failed: fatal: repository 'https://github.com/o/missing.git/' not found")
        XCTAssertEqual(oss.requests("DELETE", containing: "/v1/agents/c1").count, 1)
        XCTAssertFalse(server.sessions.contains { $0.info.id == "s2" })
    }

    func testARepositoryIsClonedFromWhereItIsNamed() {
        XCTAssertEqual(VisorServer.cloneURL(repository: "AttilaTheFun/visor"), "https://github.com/AttilaTheFun/visor.git")
        XCTAssertEqual(VisorServer.cloneURL(repository: "git@github.com:o/r.git"), "git@github.com:o/r.git")
        XCTAssertEqual(VisorServer.cloneURL(repository: "https://gitlab.com/o/r"), "https://gitlab.com/o/r")
        XCTAssertEqual(VisorServer.containerFolder(repository: "git@github.com:o/r.git"), "/root/work/r")
        XCTAssertEqual(VisorServer.containerFolder(repository: "https://gitlab.com/o/r"), "/root/work/r")
        XCTAssertEqual(VisorServer.containerFolder(repository: nil), "/root/work")
    }

    /// The agent an earlier launch left running in its container is picked
    /// up, and what is said next goes to it, not to a new one.
    func testAnAgentLeftRunningIsPickedUpAndTold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        let oss = FakeOSS(ends: false)
        ServerPlatform.current.fetching = oss
        let server = VisorServer(port: 7996)
        defer { server.stop() }
        server.settings.ossServer = "http://oss.test:7480"
        server.setOSSToken("secret")
        var info = SessionInfo(id: "s2", agent: .claude, cwd: "/root/work", title: "Claude", created: 0)
        info.container = SessionContainer(server: "http://oss.test:7480", id: "c1")
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: "r1"), entries: [])
        server.sessions.append(record)
        server.pickUp(record, container: StoredContainerProcess(process: "p1", out: 0, err: 0, carried: nil))
        XCTAssertNotNil((record.process as? HostableProcess)?.containerChild, "the agent left running is this session's again")
        server.deliver("Carry on", to: record)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(oss.requests("POST", containing: "/processes").filter { $0.url.hasSuffix("/processes") }.isEmpty, "no new agent started")
        let told = oss.requests("POST", containing: "/processes/p1/input").map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertEqual(told.count, 1)
        XCTAssertTrue(told.first?.contains("Carry on") == true)
        XCTAssertEqual(record.stored.containerProcess?.process, "p1")
        XCTAssertNil(record.stored.agentPID)
    }

    func testAContainerOnTheWireAndOnDisk() throws {
        var info = SessionInfo(id: "s", agent: .codex, cwd: "/root/work", title: "Codex", created: 0)
        info.container = SessionContainer(server: "http://oss.test:7480", id: "c1", image: "visor-agent")
        XCTAssertEqual(SessionInfo(json: info.json)?.container, info.container)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info)).container, info.container)
        let start = Envelope.decode(Envelope.startInContainer(id: "s", agent: .codex, title: "", skipPermissions: true, repository: "o/r").encoded())
        XCTAssertEqual(start?.container, true)
        XCTAssertEqual(start?.repository, "o/r")
        let stored = StoredContainerProcess(process: "p1", out: 120, err: 4, carried: ["turn": "t"])
        XCTAssertEqual(try JSONDecoder().decode(StoredContainerProcess.self, from: JSONEncoder().encode(stored)), stored)
        // Read back with its session, as the next launch reads it.
        let session = StoredSession(info: info, entries: [], resumeID: "r", shape: StoredSession.currentShape, containerProcess: stored)
        XCTAssertEqual(try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(session)).containerProcess, stored)
    }
}
