// The seam where an agent's host is started (AgentHostSpawner, 0.66): the
// request the server makes (AgentHostSpawnRequest: JSON, its credential
// apart, given back to the host as it was), the server's own spawner's
// command line as before, and the hosts' sockets placed in the app group's
// container with short names, every one under 104 bytes.

import AgentHostWire
import Foundation
@testable import VisorAgent
import VisorSystem
import Testing

/// A spawner standing in: what it was asked, and a host that's running or
/// not, or a refusal.
@MainActor
private final class FakeSpawner: AgentHostSpawner {
    var asked: [(request: AgentHostSpawnRequest, program: String)] = []
    var running = true
    var refuses = false

    final class Host: SpawnedAgentHost {
        let running: Bool
        init(running: Bool) { self.running = running }
        var isRunning: Bool { running }
    }

    func spawn(_ request: AgentHostSpawnRequest, program: String) throws -> any SpawnedAgentHost {
        if refuses { throw AgentProcessError.spawnFailed("refused") }
        asked.append((request, program))
        return Host(running: running)
    }
}

/// Hosts that never listen.
private struct SilentHosting: AgentHosting {
    var program: String { "/opt/visor/visor-agent-host" }
    func problem() -> String? { nil }
    @MainActor func connect(_ path: String) async -> (any ByteStream)? { nil }
}

extension ServerTests {
@Suite @MainActor final class AgentHostSpawnerTests {
    private let scratch = URL(fileURLWithPath: "/tmp/vs-" + String(UUID().uuidString.prefix(8)), isDirectory: true)

    init() { TestPlatform.install() }

    isolated deinit {
        AgentChildren.placedSocketFolder = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private let environment = ["PATH": "/usr/bin", "VISOR_SESSION": "s1", "VISOR_TOKEN": "jwt", "VISOR_TOKEN_FILE": "/d/hosts/s1/token"]

    private func request(_ environment: [String: String]) -> AgentHostSpawnRequest {
        AgentHostSpawnRequest(session: "s1", folder: "/work", harness: "claude", executable: "/bin/claude", arguments: ["-p", "x"],
                              environment: environment, socket: "/r/h-00000001.sock", memoryLimit: 7, log: "/d/hosts/hosts.log")
    }

    // MARK: The request

    @Test func theCredentialIsApartAndGivenBackAsItWas() {
        let request = request(environment)
        #expect(request.token == "jwt")
        #expect(request.tokenFile == "/d/hosts/s1/token")
        #expect(request.environment == ["PATH": "/usr/bin", "VISOR_SESSION": "s1"])
        #expect(request.processEnvironment == environment, "the host's process is given what it was before")
        #expect(self.request(["PATH": "/usr/bin"]).processEnvironment == ["PATH": "/usr/bin"])
    }

    @Test func itIsJSONOfVersion1() throws {
        let request = request(environment)
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(AgentHostSpawnRequest.self, from: data) == request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "session", "folder", "harness", "executable", "arguments", "environment", "token",
                                     "tokenFile", "socket", "memoryLimit", "log"])
        #expect(object["version"] as? Int == 1)
    }

    @Test func theHostsCommandLineIsAsBefore() {
        #expect(request(environment).hostArguments == ["--socket", "/r/h-00000001.sock", "--directory", "/work", "--memory-limit", "7", "--",
                                                       "/bin/claude", "-p", "x"])
    }

    // MARK: HostedChild through a spawner

    @Test func aHostIsStartedThroughTheSpawnerGiven() throws {
        let spawner = FakeSpawner()
        let child = try HostedChild.start(executable: "/bin/claude", arguments: ["-p"], directory: "/tmp", environment: environment,
                                          session: "s1", harness: "claude", in: scratch, memoryLimit: 9, hosting: SilentHosting(),
                                          spawner: spawner)
        let asked = try #require(spawner.asked.first)
        #expect(asked.program == "/opt/visor/visor-agent-host")
        #expect(asked.request.session == "s1")
        #expect(asked.request.harness == "claude")
        #expect(asked.request.folder == "/tmp")
        #expect(asked.request.socket == child.socket)
        #expect(asked.request.socket.hasPrefix(scratch.path + "/s1-"), "named as before, beside the log")
        #expect(asked.request.log == scratch.appendingPathComponent("hosts.log").path)
        #expect(asked.request.memoryLimit == 9)
        #expect(asked.request.processEnvironment == environment)
    }

    @Test func theHarnessIsTheProgramsNameWhenNotSaid() throws {
        let spawner = FakeSpawner()
        _ = try HostedChild.start(executable: "/usr/local/bin/codex", arguments: [], directory: "/tmp", environment: [:], session: "s2",
                                  in: scratch, memoryLimit: 0, hosting: SilentHosting(), spawner: spawner)
        #expect(spawner.asked.first?.request.harness == "codex")
    }

    @Test func aSpawnerThatRefusesIsTheStartsError() {
        let spawner = FakeSpawner()
        spawner.refuses = true
        #expect(throws: AgentProcessError.self) {
            try HostedChild.start(executable: "/bin/claude", arguments: [], directory: "/tmp", environment: [:], session: "s3", in: scratch,
                                  memoryLimit: 0, hosting: SilentHosting(), spawner: spawner)
        }
    }

    @Test func aHostThatIsntRunningEndsTheAgent() async throws {
        let spawner = FakeSpawner()
        spawner.running = false
        let child = try HostedChild.start(executable: "/bin/claude", arguments: [], directory: "/tmp", environment: [:], session: "s4",
                                          in: scratch, memoryLimit: 0, hosting: SilentHosting(), spawner: spawner)
        let exit = await child.exit.value
        #expect(exit.status == -1)
        #expect(!child.isRunning)
    }

    // MARK: Short names in the app group's container

    @Test func placedSocketsHaveShortNamesUnder104Bytes() throws {
        // As long a folder as the app group's container's `r/` is for a
        // 26-character user name.
        let folder = URL(fileURLWithPath: "/Users/" + String(repeating: "u", count: 26)
                         + "/Library/Group Containers/group.com.LoganShire.Visor/r", isDirectory: true)
        for _ in 0..<50 {
            let path = HostedChild.shortSocketPath(in: folder)
            let name = URL(fileURLWithPath: path).lastPathComponent
            #expect(name.hasPrefix("h-") && name.hasSuffix(".sock") && name.count == 15, Comment(rawValue: name))
            let hex = name.dropFirst(2).dropLast(5).allSatisfy { $0.isHexDigit }
            #expect(hex)
            #expect(path.utf8.count < HostedChild.socketPathLimit, Comment(rawValue: path))
        }
    }

    @Test func aPlacedFolderTakesTheHostsSocketsWithShortNames() throws {
        AgentChildren.placedSocketFolder = scratch.appendingPathComponent("r", isDirectory: true)
        #expect(AgentChildren.socketFolder(environment: [:]) == scratch.appendingPathComponent("r", isDirectory: true))
        #expect(AgentChildren.shortSocketNames(environment: [:]))
        // VISOR_RUNTIME_DIR still wins, with names as before.
        #expect(AgentChildren.socketFolder(environment: ["VISOR_RUNTIME_DIR": "/run/visor"]).path == "/run/visor/hosts")
        #expect(!AgentChildren.shortSocketNames(environment: ["VISOR_RUNTIME_DIR": "/run/visor"]))
        let spawner = FakeSpawner()
        _ = try HostedChild.start(executable: "/bin/claude", arguments: [], directory: "/tmp", environment: [:], session: "s5", in: scratch,
                                  socketsIn: AgentChildren.socketFolder(environment: [:]), shortNames: true, memoryLimit: 0,
                                  hosting: SilentHosting(), spawner: spawner)
        let socket = try #require(spawner.asked.first?.request.socket)
        #expect(socket.hasPrefix(scratch.path + "/r/h-"))
        AgentChildren.placedSocketFolder = nil
        #expect(AgentChildren.socketFolder(environment: [:]) == AgentChildren.folder, "unplaced: beside the hosts' log, as before")
        #expect(!AgentChildren.shortSocketNames(environment: [:]))
    }

    @Test func aShortNameTooLongForASocketIsRefused() {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 90), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: long) }
        #expect(throws: AgentProcessError.self) {
            try HostedChild.start(executable: "/bin/claude", arguments: [], directory: "/tmp", environment: [:], session: "s6", in: scratch,
                                  socketsIn: long, shortNames: true, memoryLimit: 0, hosting: SilentHosting(), spawner: FakeSpawner())
        }
    }
}
}
