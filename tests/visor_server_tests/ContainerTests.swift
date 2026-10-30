// Sessions whose agents run in containers, made by a container host
// (docs/container-host.md): the server asks the host for the container (the
// session's folder, the agent's log folder and Visor's tools mounted; a disk
// of its own for builds), puts the sign-ins for containers into its home and
// makes it an SSH key, runs the agent there under its host through the
// host's `exec` with its variables in a file only this user reads, moves a
// session into and out of its container, makes a container again when its
// network is lost, and says so on the wire. The host is a script here.

import ClaudeTranscript
import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

/// A container host played by a script: each call written down, answers as
/// the test sets them (files beside it: `busy`, `unhealthy`, `nonetwork`,
/// `listed.json`).
private struct FakeHost {
    let folder: URL

    var path: String { folder.appendingPathComponent("host").path }

    init(in root: URL) throws {
        folder = root.appendingPathComponent("host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = #"""
            #!/bin/bash
            dir="$(dirname "$0")"
            op="$1"; shift
            echo "$op $*" >> "$dir/calls"
            case "$op" in
              health)
                if [ -f "$dir/unhealthy" ]; then echo '{"ok":false,"error":"no runtime"}'; else echo '{"ok":true,"name":"fake","version":"1","api":1}'; fi ;;
              create)
                n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 )); echo $n > "$dir/count"
                cat > "$dir/request-$n.json"
                if [ -f "$dir/busy" ]; then echo '{"error":"no room","code":"busy"}'; exit 1; fi
                echo "{\"id\":\"c$n\",\"name\":\"made\"}" ;;
              put)
                cat > "$dir/put-$(echo "$2" | tr '/' '_')"
                echo "{\"path\":\"$2\",\"size\":1}" ;;
              exec)
                echo "ran" ;;
              rm)
                echo "{\"removed\":\"$1\"}" ;;
              ls)
                if [ -f "$dir/listed.json" ]; then cat "$dir/listed.json"; else echo '{"containers":[]}'; fi ;;
              network)
                if [ -f "$dir/nonetwork" ]; then echo '{"ok":false,"dns":false,"detail":"EAI_AGAIN"}'; else echo '{"ok":true,"detail":"fine"}'; fi ;;
            esac
            """#
        try script.write(to: folder.appendingPathComponent("host"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// The calls made, one a line: the operation and its arguments.
    var calls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The `create` request asked for, the `n`th (from 1).
    func request(_ n: Int) throws -> ContainerHostRequest {
        try JSONDecoder().decode(ContainerHostRequest.self, from: Data(contentsOf: folder.appendingPathComponent("request-\(n).json")))
    }

    func set(_ name: String, _ contents: String = "") throws {
        try contents.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

@MainActor
final class ContainerTests: ServerTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-container-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        ServerPlatform.current.host.dataDirectory = root
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        ClaudeSessionFiles.home = root
    }

    override func tearDown() async throws {
        ClaudeSessionFiles.home = FileManager.default.homeDirectoryForCurrentUser
        try? FileManager.default.removeItem(at: root)
    }

    /// A server whose containers come from `host`, reachable from the
    /// network (as an agent in a container reaches it), its check made.
    private func server(_ host: FakeHost?, port: UInt16) async -> VisorServer {
        let server = VisorServer(port: port)
        server.settings.lan = true
        server.settings.containerHost = host.map { [$0.path] } ?? ["/no/such/container-host"]
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
        let host = try FakeHost(in: root)
        let server = await server(host, port: 7997)
        defer { server.stop() }
        XCTAssertTrue(server.containersAvailable)
        XCTAssertEqual(server.sessionsEnvelope().container, true, "clients are told a session can start in a container")

        let folder = root.appendingPathComponent("work").path
        let made = try await start(server, .startInContainer(id: "S1", agent: .claude, cwd: folder, title: "", skipPermissions: true)).get()
        XCTAssertEqual(made.info.cwd, folder)
        XCTAssertEqual(made.info.container, SessionContainer(id: "c1", image: server.defaultContainerImage, size: VisorServer.fitted(.standard)))
        let asked = try host.request(1)
        XCTAssertEqual(asked.image, server.defaultContainerImage, "Visor's own image, with the agents in it")
        XCTAssertTrue(asked.rosetta, "x86_64 Linux programs too (Android's build tools)")
        XCTAssertEqual(asked.labels, ["visor.session": "S1", "visor.server": server.id], "so the host's leftovers are known")
        let resolved = HostFolders.resolve(folder)
        XCTAssertTrue(asked.mounts.contains(.init(source: resolved, destination: resolved)), "the folder, at the same path")
        // This computer's log folder for it (by its real path: the temporary
        // folder is under /private on a Mac), at the name Claude in the
        // container gives the folder as mounted.
        let here = ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: resolved)).path
        let there = "/root/.claude/projects/" + ClaudeSessionFiles.projectDirectoryName(for: resolved, followingLinks: false)
        XCTAssertTrue(asked.mounts.contains { $0.source == here && $0.destination == there && !$0.readOnly }, "where Claude keeps its log, seen here")
        XCTAssertTrue(asked.mounts.contains { $0.destination == ContainerPlacement.toolsFolder && $0.readOnly }, "Visor's tools")
        let tools = try XCTUnwrap(asked.mounts.first { $0.destination == ContainerPlacement.toolsFolder }).source
        XCTAssertEqual(try String(contentsOfFile: tools + "/visor_mcp.js", encoding: .utf8), VisorMCPScript.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools + "/visor"), "machines are the proxied MCP servers' now")
        // The sign-ins put into its home, then its own SSH key.
        let calls = host.calls.filter { !$0.hasPrefix("health") && !$0.hasPrefix("ls") }
        XCTAssertEqual(calls.first, "create ")
        XCTAssertTrue(calls.contains("put c1 /root/.codex/auth.json --mode=600"))
        XCTAssertEqual(try Data(contentsOf: host.folder.appendingPathComponent("put-_root_.codex_auth.json")), Data("{\"auth\":1}".utf8))
        XCTAssertTrue(calls.last?.hasPrefix("exec c1 -- sh -c") == true && calls.last?.contains("ssh-keygen") == true)
        XCTAssertNotNil((made.process as? HostableProcess)?.container)
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

    /// The host is the one set, else visor-container-host on the PATH, else
    /// none: sessions run on this computer only.
    func testTheHostIsTheOneSetOrTheOneOnThePath() {
        XCTAssertEqual(ContainerHost.found(setting: ShellCommand("/opt/oss", ["container-host"]), onPath: { _ in "/usr/local/bin/visor-container-host" }),
                       ContainerHost(command: ShellCommand("/opt/oss", ["container-host"])))
        XCTAssertEqual(ContainerHost.found(setting: nil, onPath: { $0 == "visor-container-host" ? "/usr/local/bin/visor-container-host" : nil }),
                       ContainerHost(command: ShellCommand("/usr/local/bin/visor-container-host")))
        XCTAssertNil(ContainerHost.found(setting: nil, onPath: { _ in nil }))
        // The agent's command line: the host's exec, which becomes it.
        let host = ContainerHost(command: ShellCommand("/opt/oss", ["container-host"]))
        XCTAssertEqual(host.command(container: "c1", executable: "claude", arguments: ["-p"], directory: "/work", environmentFile: "/tmp/s.env"),
                       ShellCommand("/opt/oss", ["container-host", "exec", "c1", "--interactive", "--workdir=/work", "--env-file=/tmp/s.env",
                                                 "--", "claude", "-p"]))
    }

    /// Codex in a container: the containers' own Codex home (one sign-in for
    /// all, never a copy of the computer's), the computer's sessions folder
    /// in it.
    func testCodexInAContainerHasTheContainersOwnHome() async throws {
        let host = try FakeHost(in: root)
        let server = await server(host, port: 7990)
        defer { server.stop() }
        _ = try await start(server, .startInContainer(id: "c1", agent: .codex, cwd: root.appendingPathComponent("work").path, title: "",
                                                      skipPermissions: true)).get()
        let mounts = try host.request(1).mounts
        let home = try XCTUnwrap(mounts.firstIndex { $0.destination == "/root/.codex" })
        let sessions = try XCTUnwrap(mounts.firstIndex { $0.destination == "/root/.codex/sessions" })
        XCTAssertEqual(mounts[home].source, root.appendingPathComponent("containers/codex").path)
        XCTAssertLessThan(home, sessions, "the home first, the sessions folder in it after")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: mounts[home].source)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "this user's alone")
    }

    /// openrouter in a container: the containers' own openrouter home (their
    /// key), the computer's sessions folder in it.
    func testOpenRouterInAContainerHasTheContainersOwnHome() async throws {
        let host = try FakeHost(in: root)
        let server = await server(host, port: 7970)
        defer { server.stop() }
        _ = try await start(server, .startInContainer(id: "o1", agent: .openrouter, cwd: root.appendingPathComponent("work").path, title: "",
                                                      skipPermissions: true)).get()
        let mounts = try host.request(1).mounts
        let home = try XCTUnwrap(mounts.firstIndex { $0.destination == "/root/.openrouter" })
        let sessions = try XCTUnwrap(mounts.firstIndex { $0.destination == "/root/.openrouter/sessions" })
        XCTAssertEqual(mounts[home].source, root.appendingPathComponent("containers/openrouter").path)
        XCTAssertEqual(mounts[sessions].source, root.appendingPathComponent(".openrouter/sessions").path)
        XCTAssertLessThan(home, sessions, "the home first, the sessions folder in it after")
        XCTAssertFalse(mounts.contains { $0.destination.hasPrefix("/root/.claude") }, "none of Claude's folders")
    }

    /// A client signed in over the WebSocket hears that a session can start
    /// in a container (its welcome), and hears again with the list when
    /// that changes.
    func testTheLiveChannelSaysWhetherContainersAreOnOffer() async throws {
        let server = await server(try FakeHost(in: root), port: 7971)
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
    /// 6 cores, 16 GB and 128 GB unless asked otherwise; its disk for builds
    /// is a volume at Bazel's output folder.
    func testAContainerIsGivenTheSizeAskedFor() async throws {
        let host = try FakeHost(in: root)
        let server = await server(host, port: 7973)
        defer { server.stop() }
        let gigabyte = ContainerSize.gigabyte
        let work = root.appendingPathComponent("work").path
        let standard = try await start(server, .startInContainer(id: "z1", agent: .claude, cwd: work, title: "", skipPermissions: true)).get()
        XCTAssertEqual(standard.info.container?.size, VisorServer.fitted(.standard))
        let first = try host.request(1)
        XCTAssertEqual(first.cpus, VisorServer.fitted(.standard).cpus)
        XCTAssertEqual(first.volumes, [.init(name: "visor-z1-build", destination: "/var/cache/bazel", sizeBytes: 128 * gigabyte)])

        let asked = ContainerSize(cpus: 2, memoryBytes: 4 * gigabyte, diskBytes: 64 * gigabyte)
        let sized = try await start(server, .startInContainer(id: "z2", agent: .claude, cwd: work, title: "", skipPermissions: true,
                                                              size: asked)).get()
        XCTAssertEqual(sized.info.container?.size, VisorServer.fitted(asked))
        let second = try host.request(2)
        XCTAssertEqual(second.cpus, VisorServer.fitted(asked).cpus)
        XCTAssertEqual(second.memoryBytes, VisorServer.fitted(asked).memoryBytes)
        XCTAssertEqual(second.volumes.first?.sizeBytes, 64 * gigabyte)

        let fitted = VisorServer.fitted(ContainerSize(cpus: 64, memoryBytes: 200 * gigabyte, diskBytes: 1), cores: 12,
                                        memory: UInt64(32 * gigabyte))
        XCTAssertEqual(fitted, ContainerSize(cpus: 12, memoryBytes: 28 * gigabyte, diskBytes: 16 * gigabyte))
        let moved = Envelope.decode(Envelope.contain(session: "z1", true, size: asked).encoded())
        XCTAssertEqual(moved?.containerSize, asked)
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
    func testAMissingFolderSaysSoAndMakesNoContainer() async throws {
        let host = try FakeHost(in: root)
        let server = await server(host, port: 7994)
        defer { server.stop() }
        let ended = await start(server, .startInContainer(id: "s2", agent: .codex, cwd: "/no/such/folder", title: "", skipPermissions: true))
        guard case .failure(let failure) = ended else { return XCTFail("started all the same") }
        XCTAssertEqual(failure.message, "There is no folder /no/such/folder on this computer.")
        XCTAssertFalse(host.calls.contains { $0.hasPrefix("create") })
        XCTAssertFalse(server.sessions.contains { $0.info.id == "s2" })
    }

    /// Containers need a container host that says it can make them, and a
    /// server on the network: without either none can start, and the
    /// clients are not offered it.
    func testContainersNeedAHostAndTheNetwork() async throws {
        let none = await server(nil, port: 7993)
        defer { none.stop() }
        XCTAssertFalse(none.containersAvailable, "no host")
        XCTAssertEqual(none.sessionsEnvelope().container, false, "the clients are told so")

        let sick = try FakeHost(in: root)
        try sick.set("unhealthy")
        let unhealthy = await server(sick, port: 7989)
        defer { unhealthy.stop() }
        XCTAssertFalse(unhealthy.containersAvailable, "a host that says it can't")

        let loopback = await server(try FakeHost(in: root), port: 7992)
        defer { loopback.stop() }
        XCTAssertTrue(loopback.containersAvailable)
        loopback.settings.lan = false
        loopback.settings.vpn = false
        await loopback.checkContainers()
        XCTAssertFalse(loopback.containersAvailable, "an agent in a container reaches the server over the network")
    }

    /// A host with no room says so in words New Session shows, and nothing
    /// is left behind.
    func testABusyHostSaysSo() async throws {
        let host = try FakeHost(in: root)
        try host.set("busy")
        let server = await server(host, port: 7984)
        defer { server.stop() }
        let ended = await start(server, .startInContainer(id: "f1", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "",
                                                          skipPermissions: true))
        guard case .failure(let failure) = ended else { return XCTFail("started all the same") }
        XCTAssertEqual(failure.message, VisorServer.containerRefusal(ContainerHostError(message: "no room", code: "busy")))
        XCTAssertTrue(failure.message.contains("no room"))
        XCTAssertFalse(server.sessions.contains { $0.info.id == "f1" })
    }

    /// The agent's variables (and the sign-ins for containers) go to the
    /// host's exec in a file this user alone reads, never on a command line;
    /// this computer's own agents/<kind>.env is not among them.
    func testAnAgentInAContainerHasItsVariablesInAFileOfItsOwn() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "GIT_AUTHOR_NAME=Here\n".write(to: root.appendingPathComponent("agents/claude.env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("containers"), withIntermediateDirectories: true)
        try "CLAUDE_CODE_OAUTH_TOKEN=sign-in\n".write(to: root.appendingPathComponent("containers/agent.env"), atomically: true, encoding: .utf8)
        let host = try FakeHost(in: root)
        let server = await server(host, port: 7995)
        defer { server.stop() }
        AgentChildren.detach = false
        defer { AgentChildren.detach = true }
        var info = SessionInfo(id: "h", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "Here", created: 0)
        XCTAssertEqual(server.makeProcess(info, resume: nil).approvalEnvironment["GIT_AUTHOR_NAME"], "Here")
        info.container = SessionContainer(id: "c9", socket: "/tmp/fake-oss-c9.sock")
        XCTAssertNil(server.placement(for: info), "OS Server's, from before container hosts: nothing to run it through")
        info.container = SessionContainer(id: "c9")
        let placement = try XCTUnwrap(server.placement(for: info))
        let child = try AgentChildren.start(executable: "claude", arguments: ["-p"], directory: info.cwd,
                                            environment: ["VISOR_SESSION": "h"], session: "h", container: placement)
        child.closeInput()
        _ = await child.exit.value
        let call = try XCTUnwrap(host.calls.first { $0.hasPrefix("exec c9 --interactive") })
        XCTAssertTrue(call.hasSuffix("-- claude -p"), call)
        let file = try XCTUnwrap(call.split(separator: " ").first { $0.hasPrefix("--env-file=") }).dropFirst("--env-file=".count)
        let text = try String(contentsOfFile: String(file), encoding: .utf8)
        XCTAssertTrue(text.contains("VISOR_SESSION=h\n"))
        XCTAssertTrue(text.contains("CLAUDE_CODE_OAUTH_TOKEN=sign-in\n"))
        XCTAssertFalse(text.contains("GIT_AUTHOR_NAME"))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: String(file))[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o077, 0, "readable by this user alone")
    }

    /// A session moves into a container and out again: the same folder,
    /// its agent made again for the other side, the container it leaves
    /// removed (its disk with it).
    func testASessionMovesIntoItsContainerAndOutAgain() async throws {
        let host = try FakeHost(in: root)
        let server = await server(host, port: 7996)
        defer { server.stop() }
        let info = SessionInfo(id: "s3", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "Claude", created: 0)
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: nil), entries: [])
        server.sessions.append(record)
        let into: Result<Void, ContainerFailure> = await withCheckedContinuation { done in server.contain(record, into: true) { done.resume(returning: $0) } }
        XCTAssertNoThrow(try into.get())
        XCTAssertEqual(record.info.container?.id, "c1")
        XCTAssertNotNil((record.process as? HostableProcess)?.container, "its agent made again for the container")
        let out: Result<Void, ContainerFailure> = await withCheckedContinuation { done in server.contain(record, into: false) { done.resume(returning: $0) } }
        XCTAssertNoThrow(try out.get())
        XCTAssertNil(record.info.container)
        XCTAssertNil((record.process as? HostableProcess)?.container)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(host.calls.contains("rm c1 --volumes"))
    }

    /// A turn that fails on the network has the container's network asked
    /// of its host; with none, the container is made again (its disk kept),
    /// the agent made again there, and the session says so. Not again for a
    /// while.
    func testAContainerThatLostItsNetworkIsMadeAgain() async throws {
        let host = try FakeHost(in: root)
        let server = await server(host, port: 7983)
        defer { server.stop() }
        let record = try await start(server, .startInContainer(id: "n1", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "",
                                                               skipPermissions: true)).get()
        try host.set("listed.json", #"{"containers":[{"id":"c1","name":"made","labels":{"visor.session":"n1"}}]}"#)
        // A failure that isn't the network's asks nothing.
        server.handle(.failure("Something else went wrong"), from: record)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(host.calls.contains { $0.hasPrefix("network") })

        try host.set("nonetwork")
        server.handle(.failure("API Error: Can't reach the API server — check your internet or DNS (EAI_AGAIN)"), from: record)
        for _ in 0..<50 where record.info.container?.id != "c2" { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(record.info.container?.id, "c2", "made again")
        XCTAssertTrue(host.calls.contains("network c1"))
        XCTAssertTrue(host.calls.contains("rm c1"), "its disk kept")
        XCTAssertTrue(record.notice?.contains("lost its network") == true)
        XCTAssertNotNil((record.process as? HostableProcess)?.container)

        // Not again so soon.
        let asked = host.calls.filter { $0.hasPrefix("network") }.count
        server.handle(.failure("EAI_AGAIN"), from: record)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(host.calls.filter { $0.hasPrefix("network") }.count, asked)
    }

    /// The host's containers for sessions this server no longer has go,
    /// with their disks; a session in a container OS Server lent (before
    /// container hosts) moves onto this computer.
    func testLeftoversGoAndOSServersContainersAreLeft() async throws {
        let host = try FakeHost(in: root)
        let server = VisorServer(port: 7982)
        defer { server.stop() }
        server.settings.lan = true
        server.settings.containerHost = [host.path]
        try host.set("listed.json", #"{"containers":[{"id":"gone","name":"x","labels":{"visor.server":"\#(server.id)","visor.session":"old"}},"#
                     + #"{"id":"other","name":"y","labels":{"visor.server":"another"}}]}"#)
        var info = SessionInfo(id: "o", agent: .claude, cwd: root.appendingPathComponent("work").path, title: "Old", created: 0)
        info.container = SessionContainer(id: "lease1", socket: "/tmp/oss-lease1.sock")
        let record = SessionRecord(info: info, process: server.makeProcess(info, resume: nil), entries: [])
        server.sessions = [record]
        await server.checkContainers()
        XCTAssertTrue(host.calls.contains("rm gone --volumes"), "its session is gone")
        XCTAssertFalse(host.calls.contains { $0.hasPrefix("rm other") }, "another server's")
        XCTAssertNil(record.info.container, "OS Server's container left; the session runs here")
        XCTAssertTrue(record.notice?.contains("OS Server's") == true)
    }

    func testAContainerOnTheWire() throws {
        var info = SessionInfo(id: "s", agent: .codex, cwd: "/Users/someone/repo", title: "Codex", created: 0)
        info.container = SessionContainer(id: "c1", image: "visor-agent", socket: "/tmp/c1.sock")
        XCTAssertEqual(SessionInfo(json: info.json)?.container, SessionContainer(id: "c1", image: "visor-agent"),
                       "the socket is the server's: never sent to a client")
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info)).container, info.container)
        let start = Envelope.decode(Envelope.startInContainer(id: "s", agent: .codex, cwd: "/Users/someone/repo", title: "", skipPermissions: true).encoded())
        XCTAssertEqual(start?.container, true)
        let contain = Envelope.decode(Envelope.contain(session: "s", false).encoded())
        XCTAssertEqual(contain?.type, "contain")
        XCTAssertEqual(contain?.container, false)
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
