// Sessions whose agents run in containers on the server's own computer: the
// server makes the container (the session's folder, the agent's log folder,
// Xcode and Visor's tools mounted; the sign-ins for containers written into
// its home; an SSH key made), runs the agent there under its host through
// the container's tool with its variables in a file only this user reads,
// moves a session into and out of its container, and says so on the wire.
// The containers are a fake here.

import ClaudeTranscript
import Foundation
import OSSClient
import Synchronization
import VisorProtocol
@testable import VisorServer
import XCTest

/// A computer's containers, as the server drives them: what it was asked.
final class FakeContainers: ContainerRunning {
    let made = Mutex<[ContainerSpec]>([])
    let removed = Mutex<[String]>([])
    let executed = Mutex<[(name: String, command: [String], input: Data?)]>([])
    let environmentFiles = Mutex<[String]>([])
    let missing: String?

    init(missing: String? = nil) {
        self.missing = missing
    }

    func problem() async -> String? { missing }

    func run(_ spec: ContainerSpec) async throws { made.withLock { $0.append(spec) } }

    func isRunning(_ name: String) async -> Bool? {
        made.withLock { made in removed.withLock { made.contains { $0.name == name } && !$0.contains(name) } } ? true : nil
    }

    /// The containers removed with their disks kept, for the next.
    let keptDisks = Mutex<[String]>([])
    func remove(_ name: String, keepingDisk: Bool) async throws {
        removed.withLock { $0.append(name) }
        if keepingDisk { keptDisks.withLock { $0.append(name) } }
    }

    /// What `stats` says.
    let reported = Mutex<[ContainerStats]>([])
    func stats() async -> [ContainerStats] { reported.withLock { $0 } }

    func execute(_ name: String, _ command: [String], input: Data?) async throws -> (status: Int32, output: String) {
        executed.withLock { $0.append((name, command, input)) }
        return (0, "")
    }

    func command(in name: String, executable: String, arguments: [String], directory: String, environmentFile: String) -> ShellCommand {
        environmentFiles.withLock { $0.append(environmentFile) }
        return ShellCommand("/bin/sh", ["-c", "cat >/dev/null"])
    }
}

@MainActor
final class ContainerTests: ServerTestCase {
    private var platform: ServerPlatform!
    private var root: URL!

    override func setUp() async throws {
        platform = ServerPlatform.current
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        ServerPlatform.current.host.dataDirectory = root
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        ClaudeSessionFiles.home = root
    }

    override func tearDown() async throws {
        ServerPlatform.current = platform
        ClaudeSessionFiles.home = FileManager.default.homeDirectoryForCurrentUser
        try? FileManager.default.removeItem(at: root)
    }

    /// A server whose computer runs `containers`, reachable from the network
    /// (as an agent in a container reaches it), its check made.
    private func server(_ containers: FakeContainers, port: UInt16) async -> VisorServer {
        ServerPlatform.current.containers = containers
        let server = VisorServer(port: port)
        server.settings.lan = true
        await server.checkContainers()
        return server
    }

    private func start(_ server: VisorServer, _ envelope: Envelope) async -> Result<SessionRecord, ContainerFailure> {
        await withCheckedContinuation { done in server.startInContainer(envelope, from: nil) { done.resume(returning: $0) } }
    }

    func testASessionStartsInAContainerThatSeesItsFolder() async throws {
        let signIns = root.appendingPathComponent("containers/home/.codex", isDirectory: true)
        try FileManager.default.createDirectory(at: signIns, withIntermediateDirectories: true)
        try Data("{\"auth\":1}".utf8).write(to: signIns.appendingPathComponent("auth.json"))
        let containers = FakeContainers()
        let server = await server(containers, port: 7997)
        defer { server.stop() }
        XCTAssertTrue(server.containersAvailable)
        XCTAssertEqual(server.sessionsEnvelope().container, true, "clients are told a session can start in a container")

        let folder = root.appendingPathComponent("work").path
        let made = try await start(server, .startInContainer(id: "S1", agent: .claude, cwd: folder, title: "", skipPermissions: true)).get()
        XCTAssertEqual(made.info.cwd, folder)
        XCTAssertEqual(made.info.container, SessionContainer(id: "visor-s1", image: "visor-agent", size: VisorServer.fitted(.standard)))
        let spec = try XCTUnwrap(containers.made.withLock { $0.first })
        XCTAssertEqual(spec.image, "visor-agent", "Visor's own image, with the agents in it")
        XCTAssertEqual(spec.labels["visor.session"], "S1")
        let resolved = HostFolders.resolve(folder)
        XCTAssertTrue(spec.mounts.contains(ContainerMount(source: resolved, target: resolved)), "the folder, at the same path")
        let project = ClaudeSessionFiles.projectDirectoryName(for: resolved)
        XCTAssertTrue(spec.mounts.contains { $0.target == "/root/.claude/projects/" + project && !$0.readOnly }, "where Claude keeps its log, seen here")
        XCTAssertTrue(spec.mounts.contains { $0.target == ContainerPlacement.toolsFolder && $0.readOnly }, "Visor's tools")
        let tools = try XCTUnwrap(spec.mounts.first { $0.target == ContainerPlacement.toolsFolder }).source
        XCTAssertEqual(try String(contentsOfFile: tools + "/visor_mcp.js", encoding: .utf8), VisorMCPScript.source)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tools + "/visor"))
        let executed = containers.executed.withLock { $0 }
        XCTAssertEqual(executed.first?.command.last, "/root/.codex/auth.json", "the sign-ins copied into its home")
        XCTAssertEqual(executed.first?.input, Data("{\"auth\":1}".utf8))
        XCTAssertTrue(executed.last?.command.last?.contains("ssh-keygen") == true, "its own SSH key, for the machines it leases")
        XCTAssertNotNil((made.process as? HostableProcess)?.container)
    }

    /// Codex in a container: the containers' own Codex home (one sign-in for
    /// all, never a copy of the computer's), the computer's sessions folder
    /// in it.
    func testCodexInAContainerHasTheContainersOwnHome() async throws {
        let containers = FakeContainers()
        let server = await server(containers, port: 7990)
        defer { server.stop() }
        _ = try await start(server, .startInContainer(id: "c1", agent: .codex, cwd: root.appendingPathComponent("work").path, title: "",
                                                      skipPermissions: true)).get()
        let mounts = try XCTUnwrap(containers.made.withLock { $0.first }).mounts
        let home = try XCTUnwrap(mounts.firstIndex { $0.target == "/root/.codex" })
        let sessions = try XCTUnwrap(mounts.firstIndex { $0.target == "/root/.codex/sessions" })
        XCTAssertEqual(mounts[home].source, root.appendingPathComponent("containers/codex").path)
        XCTAssertLessThan(home, sessions, "the home first, the sessions folder in it after")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: mounts[home].source)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "this user's alone")
    }

    /// openrouter in a container: the containers' own openrouter home (their
    /// key), the computer's sessions folder in it, where the server reads
    /// the session's log.
    func testOpenRouterInAContainerHasTheContainersOwnHome() async throws {
        let containers = FakeContainers()
        let server = await server(containers, port: 7970)
        defer { server.stop() }
        _ = try await start(server, .startInContainer(id: "o1", agent: .openrouter, cwd: root.appendingPathComponent("work").path, title: "",
                                                      skipPermissions: true)).get()
        let mounts = try XCTUnwrap(containers.made.withLock { $0.first }).mounts
        let home = try XCTUnwrap(mounts.firstIndex { $0.target == "/root/.openrouter" })
        let sessions = try XCTUnwrap(mounts.firstIndex { $0.target == "/root/.openrouter/sessions" })
        XCTAssertEqual(mounts[home].source, root.appendingPathComponent("containers/openrouter").path)
        XCTAssertEqual(mounts[sessions].source, root.appendingPathComponent(".openrouter/sessions").path)
        XCTAssertLessThan(home, sessions, "the home first, the sessions folder in it after")
        XCTAssertFalse(mounts.contains { $0.target.hasPrefix("/root/.claude") }, "none of Claude's folders")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: mounts[home].source)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "this user's alone")
    }

    /// A client signed in over the WebSocket hears that a session can start
    /// in a container (its welcome), and hears again with the list when
    /// that changes: New Session offered no Runs to a phone on the live
    /// channel, whose welcome never said.
    func testTheLiveChannelSaysWhetherContainersAreOnOffer() async throws {
        let containers = FakeContainers()
        let server = await server(containers, port: 7971)
        defer { server.stop() }
        server.password = "pw"
        let stream = EnvelopeStream()
        // Its socket opened, as a client's WebSocket opens it, and held.
        let upgrade = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let client = ClientConnection(stream: stream, received: Data(upgrade.utf8))
        client.start()
        server.connections[ObjectIdentifier(client)] = client
        server.handle(Envelope.login(password: "pw", client: "test"), from: client)
        let welcome = try XCTUnwrap(stream.envelopes.first { $0.type == "welcome" })
        XCTAssertEqual(welcome.container, true, "the welcome says containers are on offer")

        server.settings.lan = false
        server.settings.vpn = false
        await server.checkContainers()
        let list = try XCTUnwrap(stream.envelopes.last { $0.type == "sessions" })
        XCTAssertEqual(list.container, false, "the list says they no longer are")
    }

    /// What the computer is using and for whom: its processors between two
    /// readings, its sessions' containers by session, the machines they
    /// lease (with a word that oss does not say what each uses).
    func testResourcesSayWhatIsUsedAndForWhom() async throws {
        let containers = FakeContainers()
        let server = await server(containers, port: 7972)
        defer { server.stop() }
        _ = try await start(server, .startInContainer(id: "r1", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "",
                                                      skipPermissions: true)).get()
        let name = VisorServer.containerName(session: "r1")
        ServerPlatform.current.load = SteppingLoad()
        containers.reported.withLock { $0 = [ContainerStats(id: name, cpuMicroseconds: 1_000_000, cpus: 4, memoryUsedBytes: 1 << 30, memoryLimitBytes: 4 << 30)] }
        server.leases = ["r1": [SessionLease(id: "l1", platform: "ios", config: "iphone", state: "ready")]]

        let resources = await server.resources()
        // A quarter of four cores' ticks: one core's worth.
        XCTAssertEqual(resources.host?.cpuPercent, 100)
        XCTAssertEqual(resources.host?.cpus, 4)
        let container = try XCTUnwrap(resources.containers.first)
        XCTAssertEqual(container.session, "r1")
        XCTAssertEqual(container.cpuPercent, 0, "no processor time between its two readings")
        XCTAssertEqual(container.memoryLimitBytes, 4 << 30)
        XCTAssertEqual(resources.machines.map(\.session), ["r1"])
        XCTAssertNil(resources.machines.first?.cpuPercent, "no oss here to say")

        // oss's numbers, by lease: an emulator's and its allotment; a lease
        // oss does not mention keeps none.
        let measured = VisorServer.measured([LeaseUsage(id: "l1", platform: "android", session: "r1"), LeaseUsage(id: "l2", platform: "ios")],
                                            by: [MachineUsage(id: "l1", platform: .android, config: "phone", holder: "visor:r1", cpus: 4,
                                                              memoryLimitBytes: 4 << 30, cpuPercent: 120, memoryBytes: 3 << 30)])
        XCTAssertEqual(measured.first?.cpuPercent, 120)
        XCTAssertEqual(measured.first?.memoryLimitBytes, 4 << 30)
        XCTAssertNil(measured.last?.cpuPercent)

        // Its share of a core between readings: a second's time in two.
        let start = ContinuousClock.now
        let later = ContainerStats(id: name, cpuMicroseconds: 2_000_000)
        XCTAssertEqual(VisorServer.cpuPercent(later, since: (cpuMicroseconds: 1_000_000, at: start), at: start + .seconds(2)), 50)
        XCTAssertNil(VisorServer.cpuPercent(later, since: (cpuMicroseconds: 3_000_000, at: start), at: start + .seconds(2)),
                     "a reading from before it started again")
    }

    /// A container is given what was asked, within what the computer has:
    /// 6 cores, 16 GB and 128 GB unless asked otherwise; and made again at
    /// another size in place, its disk kept and its agent started again.
    func testAContainerIsGivenItsSizeAndResizedInPlace() async throws {
        let containers = FakeContainers()
        let server = await server(containers, port: 7973)
        defer { server.stop() }
        let gigabyte = ContainerSize.gigabyte
        let work = root.appendingPathComponent("work").path
        let standard = try await start(server, .startInContainer(id: "z1", agent: .claude, cwd: work, title: "", skipPermissions: true)).get()
        XCTAssertEqual(standard.info.container?.size, VisorServer.fitted(.standard))
        let first = try XCTUnwrap(containers.made.withLock { $0.last })
        XCTAssertEqual(first.cpus, VisorServer.fitted(.standard).cpus)
        XCTAssertEqual(first.disk, UInt64(128 * gigabyte))
        XCTAssertEqual(first.diskTarget, "/var/cache/bazel", "where Visor's image keeps Bazel's output")

        let bigger = ContainerSize(cpus: 2, memoryBytes: 4 * gigabyte, diskBytes: 64 * gigabyte)
        let moved: Result<Void, ContainerFailure> = await withCheckedContinuation { done in
            server.contain(standard, into: true, size: bigger) { done.resume(returning: $0) }
        }
        XCTAssertNoThrow(try moved.get())
        XCTAssertEqual(standard.info.container?.size, VisorServer.fitted(bigger))
        let second = try XCTUnwrap(containers.made.withLock { $0.last })
        XCTAssertEqual(containers.made.withLock { $0.count }, 2, "made again")
        XCTAssertEqual(second.cpus, 2)
        XCTAssertEqual(second.memory, UInt64(4 * gigabyte))
        XCTAssertEqual(containers.keptDisks.withLock { $0 }, [VisorServer.containerName(session: "z1")], "its disk kept for the new one")

        // Within what the computer has.
        let fitted = VisorServer.fitted(ContainerSize(cpus: 64, memoryBytes: 200 * gigabyte, diskBytes: 1), cores: 12,
                                        memory: UInt64(32 * gigabyte))
        XCTAssertEqual(fitted, ContainerSize(cpus: 12, memoryBytes: 28 * gigabyte, diskBytes: 16 * gigabyte))
        // And over the wire, both ways.
        let asked = Envelope.decode(Envelope.contain(session: "z1", true, size: bigger).encoded())
        XCTAssertEqual(asked?.containerSize, bigger)
        let told = Envelope.decode(Envelope.sessions([standard.info]).encoded())
        XCTAssertEqual(told?.sessions?.first?.container?.size, VisorServer.fitted(bigger))
    }

    /// A folder that is not on the computer says so, and no container is made.
    func testAMissingFolderSaysSoAndMakesNoContainer() async {
        let containers = FakeContainers()
        let server = await server(containers, port: 7994)
        defer { server.stop() }
        let ended = await start(server, .startInContainer(id: "s2", agent: .codex, cwd: "/no/such/folder", title: "", skipPermissions: true))
        guard case .failure(let failure) = ended else { return XCTFail("started all the same") }
        XCTAssertEqual(failure.message, "There is no folder /no/such/folder on this computer.")
        XCTAssertTrue(containers.made.withLock { $0.isEmpty })
        XCTAssertFalse(server.sessions.contains { $0.info.id == "s2" })
    }

    /// No container tool, or a server only on loopback: none can start, and
    /// the clients are not offered it.
    func testContainersNeedTheToolAndTheNetwork() async {
        let missing = await server(FakeContainers(missing: "Apple's container is not installed"), port: 7993)
        defer { missing.stop() }
        XCTAssertFalse(missing.containersAvailable)
        XCTAssertEqual(missing.sessionsEnvelope().container, false, "the clients are told so")
        ServerPlatform.current.containers = FakeContainers()
        let loopback = VisorServer(port: 7992)
        defer { loopback.stop() }
        loopback.settings.lan = false
        loopback.settings.vpn = false
        await loopback.checkContainers()
        XCTAssertFalse(loopback.containersAvailable, "an agent in a container reaches the server over the network")
    }

    /// The agent's variables (and the sign-ins for containers) go to the
    /// container's tool in a file this user alone reads, never on a command
    /// line; this computer's own agents/<kind>.env is not among them.
    func testAnAgentInAContainerHasItsVariablesInAFileOfItsOwn() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "GIT_AUTHOR_NAME=Here\n".write(to: root.appendingPathComponent("agents/claude.env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("containers"), withIntermediateDirectories: true)
        try "CLAUDE_CODE_OAUTH_TOKEN=sign-in\n".write(to: root.appendingPathComponent("containers/agent.env"), atomically: true, encoding: .utf8)
        let containers = FakeContainers()
        let server = await server(containers, port: 7995)
        defer { server.stop() }
        AgentChildren.detach = false
        defer { AgentChildren.detach = true }
        var info = SessionInfo(id: "h", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "Here", created: 0)
        XCTAssertEqual(server.makeProcess(info, resume: nil).approvalEnvironment["GIT_AUTHOR_NAME"], "Here")
        info.container = SessionContainer(id: "visor-h")
        let placement = try XCTUnwrap(server.placement(for: info))
        let child = try AgentChildren.start(executable: "claude", arguments: ["-p"], directory: info.cwd,
                                            environment: ["VISOR_SESSION": "h"], session: "h", container: placement)
        child.closeInput()
        _ = await child.exit.value
        let file = try XCTUnwrap(containers.environmentFiles.withLock { $0.first })
        let text = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertTrue(text.contains("VISOR_SESSION=h\n"))
        XCTAssertTrue(text.contains("CLAUDE_CODE_OAUTH_TOKEN=sign-in\n"))
        XCTAssertFalse(text.contains("GIT_AUTHOR_NAME"))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "readable by this user alone")
    }

    /// A session moves into a container and out again: the same folder,
    /// its agent made again for the other side, the container it leaves
    /// removed.
    func testASessionMovesIntoItsContainerAndOutAgain() async throws {
        let containers = FakeContainers()
        let server = await server(containers, port: 7996)
        defer { server.stop() }
        let info = SessionInfo(id: "s3", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "Claude", created: 0)
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: nil), entries: [])
        server.sessions.append(record)
        let into: Result<Void, ContainerFailure> = await withCheckedContinuation { done in server.contain(record, into: true) { done.resume(returning: $0) } }
        XCTAssertNoThrow(try into.get())
        XCTAssertEqual(record.info.container?.id, "visor-s3")
        XCTAssertEqual(record.info.cwd, info.cwd)
        XCTAssertNotNil((record.process as? HostableProcess)?.container, "its agent made again for the container")
        let out: Result<Void, ContainerFailure> = await withCheckedContinuation { done in server.contain(record, into: false) { done.resume(returning: $0) } }
        XCTAssertNoThrow(try out.get())
        XCTAssertNil(record.info.container)
        XCTAssertNil((record.process as? HostableProcess)?.container)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(containers.removed.withLock { $0 }, ["visor-s3"])
    }

    /// oss is set over the API as Settings sets it: its token kept with the
    /// server's own secrets, and never said back.
    func testOSSIsSetOverTheAPI() async {
        let server = await server(FakeContainers(), port: 7991)
        defer { server.stop() }
        var request = HTTPRequest(method: "POST", path: "/api/oss", headers: [:], body: #"{"server":"http://oss.test:7480","token":"secret"}"#)
        request.trusted = true
        let answer = server.route(request)
        XCTAssertEqual(server.settings.ossServer, "http://oss.test:7480")
        XCTAssertTrue(server.ossTokenKept)
        XCTAssertEqual(VisorServer.secrets.get("ossToken"), "secret")
        XCTAssertFalse(answer.body.contains("secret"), "the token is never said back")
        XCTAssertTrue(answer.body.contains(#""tokenKept":true"#))
    }

    /// A lease's ports are reached at oss's address: an address, not a
    /// `.local` name, and in a container this computer's LAN address where
    /// oss is on this computer's loopback (the container's loopback is its
    /// own).
    func testALeaseIsReachedWhereTheSessionCanReachIt() {
        let resolve: (String) -> String? = { $0 == "oss-mac.local" ? "192.168.4.40" : nil }
        XCTAssertEqual(VisorServer.leaseHost(oss: "127.0.0.1", inContainer: true, lan: "192.168.4.52", resolve: resolve), "192.168.4.52")
        XCTAssertEqual(VisorServer.leaseHost(oss: "localhost", inContainer: true, lan: "192.168.4.52", resolve: resolve), "192.168.4.52")
        XCTAssertEqual(VisorServer.leaseHost(oss: "127.0.0.1", inContainer: false, lan: "192.168.4.52", resolve: resolve), "127.0.0.1")
        XCTAssertEqual(VisorServer.leaseHost(oss: "oss-mac.local", inContainer: true, lan: "192.168.4.52", resolve: resolve), "192.168.4.40")
        XCTAssertEqual(VisorServer.leaseHost(oss: "oss.example", inContainer: false, lan: nil, resolve: resolve), "oss.example")
    }

    func testAContainerAndLeasesOnTheWire() throws {
        var info = SessionInfo(id: "s", agent: .codex, cwd: "/Users/someone/repo", title: "Codex", created: 0)
        info.container = SessionContainer(id: "visor-s", image: "visor-agent")
        info.leases = [SessionLease(id: "l1", platform: "ios", config: "vanilla", state: "ready", expires: 1_800_000_000)]
        XCTAssertEqual(SessionInfo(json: info.json)?.container, info.container)
        XCTAssertEqual(SessionInfo(json: info.json)?.leases, info.leases)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info)).container, info.container)
        let start = Envelope.decode(Envelope.startInContainer(id: "s", agent: .codex, cwd: "/Users/someone/repo", title: "", skipPermissions: true).encoded())
        XCTAssertEqual(start?.container, true)
        XCTAssertEqual(start?.cwd, "/Users/someone/repo")
        let contain = Envelope.decode(Envelope.contain(session: "s", false).encoded())
        XCTAssertEqual(contain?.type, "contain")
        XCTAssertEqual(contain?.container, false)
        // A container of the oss days (its server, its repository) reads as
        // the container it names.
        let old = Data(#"{"server":"http://oss.test:7480","id":"c1","repository":"o/r"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SessionContainer.self, from: old), SessionContainer(id: "c1"))
    }
}

/// What the server wrote to a client: the envelopes in its frames
/// (unmasked, as a server sends them).
private final class EnvelopeStream: ByteStream {
    var sent: [Data] = []
    func receive(_ chunk: @escaping @MainActor (Data?) -> Void) {}
    func send(_ data: Data, sent: (@MainActor () -> Void)?) { self.sent.append(data); sent?() }
    func close() {}

    var envelopes: [Envelope] {
        sent.compactMap { data in
            let bytes = [UInt8](data)
            guard bytes.count >= 2, bytes[0] & 0x0F == 1 else { return nil }
            let length = Int(bytes[1] & 0x7F)
            let start = length == 126 ? 4 : length == 127 ? 10 : 2
            return Envelope.decode(String(decoding: bytes[start...], as: UTF8.self))
        }
    }
}

/// A computer whose every reading has done one core's worth of work of
/// four since the last.
private final class SteppingLoad: HostLoadReading {
    private let readings = Mutex<UInt64>(0)

    func sample() -> HostLoadSample? {
        let step = readings.withLock { count in
            count += 1
            return count
        }
        return HostLoadSample(busyTicks: step * 100, totalTicks: step * 400, cpus: 4, memoryBytes: 16 << 30, memoryUsedBytes: 8 << 30)
    }
}
