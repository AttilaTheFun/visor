// Sessions whose agents run in containers on the server's own computer,
// leased from the OS Server there: the server leases the container (the
// session's folder, the agent's log folder, Xcode and Visor's tools
// mounted; a disk of its own for builds), writes the sign-ins for
// containers into its home and makes it an SSH key over its socket, runs
// the agent there under its host through OS Server's command line with its
// variables in a file only this user reads, moves a session into and out of
// its container, and says so on the wire. oss and the container's socket
// are fakes here.

import ClaudeTranscript
import Foundation
import OSSClient
import Synchronization
import VisorProtocol
@testable import VisorServer
import XCTest

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
        OSSAccess.transport = PlatformOSSTransport()
        ClaudeSessionFiles.home = FileManager.default.homeDirectoryForCurrentUser
        try? FileManager.default.removeItem(at: root)
    }

    /// A server whose computer runs commands in containers through `exec`
    /// and leases them from `oss` (this computer's, set with its token),
    /// reachable from the network (as an agent in a container reaches it),
    /// its check made.
    private func server(_ exec: FakeContainerExec?, oss: FakeOSS = FakeOSS(), servers: [String] = [FakeOSS.here],
                        port: UInt16) async -> VisorServer {
        ServerPlatform.current.containerExec = exec
        OSSAccess.transport = oss
        let server = VisorServer(port: port)
        server.settings.lan = true
        server.settings.ossServers = servers
        for each in servers { VisorServer.secrets.set(VisorServer.ossTokenKey(each), "token") }
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
        let exec = FakeContainerExec()
        let oss = FakeOSS()
        let server = await server(exec, oss: oss, port: 7997)
        defer { server.stop() }
        XCTAssertTrue(server.containersAvailable)
        XCTAssertEqual(server.sessionsEnvelope().container, true, "clients are told a session can start in a container")

        let folder = root.appendingPathComponent("work").path
        let made = try await start(server, .startInContainer(id: "S1", agent: .claude, cwd: folder, title: "", skipPermissions: true)).get()
        XCTAssertEqual(made.info.cwd, folder)
        XCTAssertEqual(made.info.container, SessionContainer(id: "c1", image: server.defaultContainerImage, size: VisorServer.fitted(.standard),
                                                             socket: "/tmp/fake-oss-c1.sock"))
        let asked = try XCTUnwrap(oss.server().asked.first)
        XCTAssertEqual(asked.platform, .container)
        XCTAssertEqual(asked.holder, "visor:S1")
        XCTAssertEqual(asked.minutes, 0, "held until released")
        let spec = try XCTUnwrap(asked.container)
        XCTAssertEqual(spec.image, server.defaultContainerImage, "Visor's own image, with the agents in it")
        XCTAssertTrue(spec.rosetta, "x86_64 Linux programs too (Android's build tools)")
        let resolved = HostFolders.resolve(folder)
        XCTAssertTrue(spec.mounts.contains(ContainerMount(source: resolved, destination: resolved)), "the folder, at the same path")
        let project = ClaudeSessionFiles.projectDirectoryName(for: resolved)
        XCTAssertTrue(spec.mounts.contains { $0.destination == "/root/.claude/projects/" + project && !$0.readOnly }, "where Claude keeps its log, seen here")
        XCTAssertTrue(spec.mounts.contains { $0.destination == ContainerPlacement.toolsFolder && $0.readOnly }, "Visor's tools")
        let tools = try XCTUnwrap(spec.mounts.first { $0.destination == ContainerPlacement.toolsFolder }).source
        XCTAssertEqual(try String(contentsOfFile: tools + "/visor_mcp.js", encoding: .utf8), VisorMCPScript.source)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: tools + "/visor"))
        let executed = exec.executed.withLock { $0 }
        XCTAssertEqual(Set(executed.map(\.socket)), ["/tmp/fake-oss-c1.sock"], "over the container's own socket")
        XCTAssertEqual(executed.first?.command.last, "/root/.codex/auth.json", "the sign-ins copied into its home")
        XCTAssertEqual(executed.first?.input, Data("{\"auth\":1}".utf8))
        XCTAssertTrue(executed.last?.command.last?.contains("ssh-keygen") == true, "its own SSH key, for the machines it leases")
        XCTAssertNotNil((made.process as? HostableProcess)?.container)
        await server.refreshLeases()
        XCTAssertEqual(made.info.leases, [], "its container is not one of its machines")
    }

    /// Visor's image is this build's, published by CI; a build CI did not
    /// number takes its version's latest.
    func testTheImageIsThisVersions() {
        let repository = VisorServer.containerImageRepository
        XCTAssertEqual(repository, "ghcr.io/attilathefun/visor-agent")
        XCTAssertEqual(VisorServer.containerImage(version: "0.40.12"), repository + ":0.40.12")
        XCTAssertEqual(VisorServer.containerImage(version: "0.40.12 (1)"), repository + ":0.40.12")
        XCTAssertEqual(VisorServer.containerImage(version: "0.40.0"), repository + ":0.40")
        XCTAssertEqual(VisorServer.containerImage(version: ""), repository + ":latest")
    }

    /// Codex in a container: the containers' own Codex home (one sign-in for
    /// all, never a copy of the computer's), the computer's sessions folder
    /// in it.
    func testCodexInAContainerHasTheContainersOwnHome() async throws {
        let oss = FakeOSS()
        let server = await server(FakeContainerExec(), oss: oss, port: 7990)
        defer { server.stop() }
        _ = try await start(server, .startInContainer(id: "c1", agent: .codex, cwd: root.appendingPathComponent("work").path, title: "",
                                                      skipPermissions: true)).get()
        let mounts = try XCTUnwrap(oss.server().asked.first?.container).mounts
        let home = try XCTUnwrap(mounts.firstIndex { $0.destination == "/root/.codex" })
        let sessions = try XCTUnwrap(mounts.firstIndex { $0.destination == "/root/.codex/sessions" })
        XCTAssertEqual(mounts[home].source, root.appendingPathComponent("containers/codex").path)
        XCTAssertLessThan(home, sessions, "the home first, the sessions folder in it after")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: mounts[home].source)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "this user's alone")
    }

    /// openrouter in a container: the containers' own openrouter home (their
    /// key), the computer's sessions folder in it, where the server reads
    /// the session's log.
    func testOpenRouterInAContainerHasTheContainersOwnHome() async throws {
        let oss = FakeOSS()
        let server = await server(FakeContainerExec(), oss: oss, port: 7970)
        defer { server.stop() }
        _ = try await start(server, .startInContainer(id: "o1", agent: .openrouter, cwd: root.appendingPathComponent("work").path, title: "",
                                                      skipPermissions: true)).get()
        let mounts = try XCTUnwrap(oss.server().asked.first?.container).mounts
        let home = try XCTUnwrap(mounts.firstIndex { $0.destination == "/root/.openrouter" })
        let sessions = try XCTUnwrap(mounts.firstIndex { $0.destination == "/root/.openrouter/sessions" })
        XCTAssertEqual(mounts[home].source, root.appendingPathComponent("containers/openrouter").path)
        XCTAssertEqual(mounts[sessions].source, root.appendingPathComponent(".openrouter/sessions").path)
        XCTAssertLessThan(home, sessions, "the home first, the sessions folder in it after")
        XCTAssertFalse(mounts.contains { $0.destination.hasPrefix("/root/.claude") }, "none of Claude's folders")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: mounts[home].source)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "this user's alone")
    }

    /// A client signed in over the WebSocket hears that a session can start
    /// in a container (its welcome), and hears again with the list when
    /// that changes: New Session offered no Runs to a phone on the live
    /// channel, whose welcome never said.
    func testTheLiveChannelSaysWhetherContainersAreOnOffer() async throws {
        let server = await server(FakeContainerExec(), port: 7971)
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

    /// A container is given what was asked, within what the computer has:
    /// 6 cores, 16 GB and 128 GB unless asked otherwise, chosen before it is
    /// made (New Session, Move into a Container); its disk for builds is a
    /// volume oss keeps, at Bazel's output folder.
    func testAContainerIsGivenTheSizeAskedFor() async throws {
        let oss = FakeOSS()
        let server = await server(FakeContainerExec(), oss: oss, port: 7973)
        defer { server.stop() }
        let gigabyte = ContainerSize.gigabyte
        let work = root.appendingPathComponent("work").path
        let standard = try await start(server, .startInContainer(id: "z1", agent: .claude, cwd: work, title: "", skipPermissions: true)).get()
        XCTAssertEqual(standard.info.container?.size, VisorServer.fitted(.standard))
        let first = try XCTUnwrap(oss.server().asked.last?.container)
        XCTAssertEqual(first.cpus, VisorServer.fitted(.standard).cpus)
        XCTAssertEqual(first.volumes, [ContainerVolume(name: "visor-z1-build", destination: "/var/cache/bazel", sizeBytes: 128 * gigabyte, keep: true)],
                       "where Visor's image keeps Bazel's output")

        let asked = ContainerSize(cpus: 2, memoryBytes: 4 * gigabyte, diskBytes: 64 * gigabyte)
        let sized = try await start(server, .startInContainer(id: "z2", agent: .claude, cwd: work, title: "", skipPermissions: true,
                                                              size: asked)).get()
        XCTAssertEqual(sized.info.container?.size, VisorServer.fitted(asked))
        let second = try XCTUnwrap(oss.server().asked.last?.container)
        // As asked, where this computer has that much (a CI runner may
        // have less memory than 4 GB beside its own 4).
        XCTAssertEqual(second.cpus, VisorServer.fitted(asked).cpus)
        XCTAssertEqual(second.memoryBytes, VisorServer.fitted(asked).memoryBytes)
        XCTAssertEqual(second.volumes.first?.sizeBytes, 64 * gigabyte)

        // Within what the computer has.
        let fitted = VisorServer.fitted(ContainerSize(cpus: 64, memoryBytes: 200 * gigabyte, diskBytes: 1), cores: 12,
                                        memory: UInt64(32 * gigabyte))
        XCTAssertEqual(fitted, ContainerSize(cpus: 12, memoryBytes: 28 * gigabyte, diskBytes: 16 * gigabyte))
        // And over the wire, both ways.
        let moved = Envelope.decode(Envelope.contain(session: "z1", true, size: asked).encoded())
        XCTAssertEqual(moved?.containerSize, asked)
        let told = Envelope.decode(Envelope.sessions([sized.info]).encoded())
        XCTAssertEqual(told?.sessions?.first?.container?.size, VisorServer.fitted(asked))
    }

    /// A container's Bazel reads oss's cache, read-only: the home's
    /// .bazelrc names it and .netrc holds the read token for that host.
    func testAContainerReadsOSSsBuildCache() throws {
        let cache = CacheInfo(port: 7490, readToken: "read-token", bytes: 0, maxBytes: 1, freeBytes: 1, hits: 0, misses: 0, writes: 0, evicted: 0)
        let files = Dictionary(uniqueKeysWithValues: VisorServer.buildCacheFiles(host: "192.168.4.51", cache: cache).map { ($0.path, $0.data) })
        let rc = String(decoding: try XCTUnwrap(files[".bazelrc"]), as: UTF8.self)
        XCTAssertTrue(rc.contains("build --remote_cache=http://192.168.4.51:7490"))
        XCTAssertTrue(rc.contains("build --noremote_upload_local_results"), "read-only")
        XCTAssertFalse(rc.contains("read-token"), "the token is not in the .bazelrc, which --announce_rc prints")
        XCTAssertEqual(String(decoding: try XCTUnwrap(files[".netrc"]), as: UTF8.self), "machine 192.168.4.51 login bazel password read-token\n")
    }

    /// A bridge to the computer's own containers or VMs is none of the
    /// addresses a server gives: it is the same address on every computer.
    func testABridgeIsNotOneOfTheServersAddresses() {
        for bridge in ["bridge100", "bridge0", "docker0", "br-1a2b3c", "virbr0", "cni0", "lxcbr0"] {
            XCTAssertTrue(NetworkInterfaces.isBridge(bridge), bridge)
        }
        for network in ["en0", "en1", "utun4", "eth0", "wlan0", "tailscale0"] {
            XCTAssertFalse(NetworkInterfaces.isBridge(network), network)
        }
    }

    /// A folder that is not on the computer says so, and no container is made.
    func testAMissingFolderSaysSoAndMakesNoContainer() async {
        let oss = FakeOSS()
        let server = await server(FakeContainerExec(), oss: oss, port: 7994)
        defer { server.stop() }
        let ended = await start(server, .startInContainer(id: "s2", agent: .codex, cwd: "/no/such/folder", title: "", skipPermissions: true))
        guard case .failure(let failure) = ended else { return XCTFail("started all the same") }
        XCTAssertEqual(failure.message, "There is no folder /no/such/folder on this computer.")
        XCTAssertTrue(oss.server().asked.isEmpty)
        XCTAssertFalse(server.sessions.contains { $0.info.id == "s2" })
    }

    /// Containers come from an OS Server on this computer that lends them,
    /// with a way to run commands in them, to a server on the network:
    /// without any of that none can start, and the clients are not offered
    /// it. Another computer's oss lends no containers here.
    func testContainersNeedThisComputersOSServerAndTheNetwork() async {
        let none = await server(nil, port: 7993)
        defer { none.stop() }
        XCTAssertFalse(none.containersAvailable, "nothing runs commands in them here")
        XCTAssertEqual(none.sessionsEnvelope().container, false, "the clients are told so")

        let old = await server(FakeContainerExec(), oss: FakeOSS(["127.0.0.1": ("this-mac", false)]), port: 7989)
        defer { old.stop() }
        XCTAssertFalse(old.containersAvailable, "an OS Server before 0.9 lends none")

        let elsewhere = await server(FakeContainerExec(), oss: FakeOSS(["mac.test": ("another-mac", true)]), servers: ["http://mac.test:7480"],
                                     port: 7988)
        defer { elsewhere.stop() }
        XCTAssertFalse(elsewhere.containersAvailable, "another computer's oss lends no containers here")

        let unset = await server(FakeContainerExec(), servers: [], port: 7987)
        defer { unset.stop() }
        XCTAssertFalse(unset.containersAvailable)

        let loopback = await server(FakeContainerExec(), port: 7992)
        defer { loopback.stop() }
        loopback.settings.lan = false
        loopback.settings.vpn = false
        await loopback.checkContainers()
        XCTAssertFalse(loopback.containersAvailable, "an agent in a container reaches the server over the network")
    }

    /// An OS Server with no room says so in words New Session shows (the
    /// mini's lends one at a time), and nothing is made.
    func testAFullOSServerSaysSo() async {
        let oss = FakeOSS()
        oss.roomFor(0)
        let server = await server(FakeContainerExec(), oss: oss, port: 7984)
        defer { server.stop() }
        let ended = await start(server, .startInContainer(id: "f1", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "",
                                                          skipPermissions: true))
        guard case .failure(let failure) = ended else { return XCTFail("started all the same") }
        XCTAssertEqual(failure.message, VisorServer.containerRefusal(OSSError(status: 409, message: "busy", code: "busy")))
        XCTAssertTrue(failure.message.contains("no room"))
        XCTAssertTrue(oss.server().asked.isEmpty)
    }

    /// The agent's variables (and the sign-ins for containers) go to OS
    /// Server's command line in a file this user alone reads, never on a
    /// command line; this computer's own agents/<kind>.env is not among
    /// them. A container from before OS Server (no socket) runs nothing.
    func testAnAgentInAContainerHasItsVariablesInAFileOfItsOwn() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "GIT_AUTHOR_NAME=Here\n".write(to: root.appendingPathComponent("agents/claude.env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("containers"), withIntermediateDirectories: true)
        try "CLAUDE_CODE_OAUTH_TOKEN=sign-in\n".write(to: root.appendingPathComponent("containers/agent.env"), atomically: true, encoding: .utf8)
        let exec = FakeContainerExec()
        let server = await server(exec, port: 7995)
        defer { server.stop() }
        AgentChildren.detach = false
        defer { AgentChildren.detach = true }
        var info = SessionInfo(id: "h", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "Here", created: 0)
        XCTAssertEqual(server.makeProcess(info, resume: nil).approvalEnvironment["GIT_AUTHOR_NAME"], "Here")
        info.container = SessionContainer(id: "visor-h")
        XCTAssertNil(server.placement(for: info), "Apple's container, from before: nothing to run it through")
        info.container = SessionContainer(id: "c9", socket: "/tmp/fake-oss-c9.sock")
        let placement = try XCTUnwrap(server.placement(for: info))
        let child = try AgentChildren.start(executable: "claude", arguments: ["-p"], directory: info.cwd,
                                            environment: ["VISOR_SESSION": "h"], session: "h", container: placement)
        child.closeInput()
        _ = await child.exit.value
        let command = try XCTUnwrap(exec.commands.withLock { $0.first })
        XCTAssertEqual(command.socket, "/tmp/fake-oss-c9.sock")
        let text = try String(contentsOfFile: command.environmentFile, encoding: .utf8)
        XCTAssertTrue(text.contains("VISOR_SESSION=h\n"))
        XCTAssertTrue(text.contains("CLAUDE_CODE_OAUTH_TOKEN=sign-in\n"))
        XCTAssertFalse(text.contains("GIT_AUTHOR_NAME"))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: command.environmentFile)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "readable by this user alone")
    }

    /// A session moves into a container and out again: the same folder,
    /// its agent made again for the other side, the container it leaves
    /// released and its disk deleted.
    func testASessionMovesIntoItsContainerAndOutAgain() async throws {
        let oss = FakeOSS()
        let server = await server(FakeContainerExec(), oss: oss, port: 7996)
        defer { server.stop() }
        let info = SessionInfo(id: "s3", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "Claude", created: 0)
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: nil), entries: [])
        server.sessions.append(record)
        let into: Result<Void, ContainerFailure> = await withCheckedContinuation { done in server.contain(record, into: true) { done.resume(returning: $0) } }
        XCTAssertNoThrow(try into.get())
        XCTAssertEqual(record.info.container?.id, "c1")
        XCTAssertEqual(record.info.cwd, info.cwd)
        XCTAssertNotNil((record.process as? HostableProcess)?.container, "its agent made again for the container")
        let out: Result<Void, ContainerFailure> = await withCheckedContinuation { done in server.contain(record, into: false) { done.resume(returning: $0) } }
        XCTAssertNoThrow(try out.get())
        XCTAssertNil(record.info.container)
        XCTAssertNil((record.process as? HostableProcess)?.container)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(oss.server().released, ["c1"])
        XCTAssertEqual(oss.server().deletedVolumes, ["visor-s3-build"])
    }

    /// A session's machines come from every server set, each used through
    /// the server that lent it; what a server lends that is not this
    /// server's sessions' is none of theirs.
    func testMachinesComeFromEveryServer() async throws {
        let oss = FakeOSS(["127.0.0.1": ("this-mac", true), "mac.test": ("another-mac", false)])
        let server = await server(FakeContainerExec(), oss: oss, servers: [FakeOSS.here, "http://mac.test:7480"], port: 7986)
        defer { server.stop() }
        let info = SessionInfo(id: "m1", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "Claude", created: 0)
        server.sessions.append(SessionRecord(info: info, process: server.makeProcess(info, resume: nil), entries: []))
        let now = Date()
        oss.hold(Lease(id: "here1", platform: .ios, config: "iphone", name: "a", holder: "visor:m1", state: .ready, created: now,
                       expires: now.addingTimeInterval(600)))
        oss.hold(Lease(id: "there1", platform: .ios, config: "iphone", name: "b", holder: "visor:m1", state: .ready, created: now,
                       expires: now.addingTimeInterval(600)), at: "mac.test")
        oss.hold(Lease(id: "theirs", platform: .ios, config: "iphone", name: "c", holder: "someone", state: .ready, created: now,
                       expires: now.addingTimeInterval(600)), at: "mac.test")
        await server.refreshLeases()
        XCTAssertEqual(server.session("m1")?.info.leases.map(\.id), ["here1", "there1"])

        let released: HTTPResponse = await withCheckedContinuation { done in
            let request = HTTPRequest(method: "DELETE", path: "/api/machines/there1?session=m1", headers: [:], body: "")
            server.answerMachines(request, parts: ["machines", "there1"]) { done.resume(returning: $0) }
        }
        XCTAssertEqual(released.status, 200)
        XCTAssertEqual(oss.server("mac.test").released, ["there1"], "released by the server that lent it")
        XCTAssertEqual(oss.server().released, [])
    }

    /// oss servers are set over the API as Settings sets them: each one's
    /// token kept with the server's own secrets, and never said back; one
    /// taken off goes with its token.
    func testOSSServersAreSetOverTheAPI() async {
        let server = await server(FakeContainerExec(), servers: [], port: 7991)
        defer { server.stop() }
        func post(_ body: String) -> HTTPResponse {
            var request = HTTPRequest(method: "POST", path: "/api/oss", headers: [:], body: body)
            request.trusted = true
            return server.route(request)
        }
        let answer = post(#"{"server":"http://oss.test:7480/","token":"secret"}"#)
        _ = post(#"{"server":"http://mini.test:7480","token":"other"}"#)
        XCTAssertEqual(server.settings.ossServers, ["http://oss.test:7480", "http://mini.test:7480"])
        XCTAssertTrue(server.ossTokenKept("http://oss.test:7480"))
        XCTAssertEqual(VisorServer.secrets.get(VisorServer.ossTokenKey("http://mini.test:7480")), "other")
        XCTAssertFalse(answer.body.contains("secret"), "a token is never said back")
        XCTAssertTrue(answer.body.contains(#""tokenKept":true"#))

        _ = post(#"{"server":"http://oss.test:7480","remove":true}"#)
        XCTAssertEqual(server.settings.ossServers, ["http://mini.test:7480"])
        XCTAssertNil(VisorServer.secrets.get(VisorServer.ossTokenKey("http://oss.test:7480")))
    }

    /// A settings file from before several servers reads its one, and the
    /// token kept for it becomes that server's.
    func testOneOSSServerFromBeforeIsKept() async throws {
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"ossServer":"http://oss.test:7480"}"#.utf8))
        XCTAssertEqual(settings.ossServers, ["http://oss.test:7480"])
        let server = await server(FakeContainerExec(), servers: [], port: 7985)
        defer { server.stop() }
        server.settings.ossServers = settings.ossServers
        VisorServer.secrets.set("ossToken", "kept")
        server.adoptOSSToken()
        XCTAssertTrue(server.ossTokenKept("http://oss.test:7480"))
        XCTAssertNil(VisorServer.secrets.get("ossToken"))
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
        info.container = SessionContainer(id: "c1", image: "visor-agent", socket: "/tmp/c1.sock")
        info.leases = [SessionLease(id: "l1", platform: "ios", config: "vanilla", state: "ready", expires: 1_800_000_000)]
        XCTAssertEqual(SessionInfo(json: info.json)?.container, SessionContainer(id: "c1", image: "visor-agent"),
                       "the socket is the server's: never sent to a client")
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
