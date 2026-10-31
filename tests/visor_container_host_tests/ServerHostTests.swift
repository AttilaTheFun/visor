// A container server's host (docs/co-tenancy.md, version 2 of the container
// host's interface) over a script that plays Apple's `container`: the
// container made with its home and Bazel disks kept, the Visor server in
// it started with its password on standard input, the agents' sign-ins
// written there and taken away, its status and code, and its clients'
// connections passed on from the host's port. The "server" is the test's
// own on this computer's loopback, started when a fake `visor-server start`
// is run; files the host writes in the container land in the fake's own
// folder.

import CVisorPOSIX
import Foundation
import Synchronization
@testable import VisorContainerHost
import XCTest

/// Apple's `container` for a container server: `run`, `inspect` (its state
/// and address, 127.0.0.1), `start`, `stop`, `delete`, volumes, and `exec`
/// — a file written lands in `fs/`, anything else runs here with
/// `visor-server` a fake on the PATH.
private struct FakeServerTool {
    let folder: URL

    var path: String { folder.appendingPathComponent("container").path }
    var tool: AppleContainer { AppleContainer(tool: path) }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("server-host-\(UUID().uuidString)", isDirectory: true)
        for sub in ["", "fs", "bin"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let container = #"""
            #!/bin/bash
            dir="$(dirname "$0")"
            echo "$*" >> "$dir/calls"
            case "$1" in
              volume)
                case "$2" in
                  inspect) [ -f "$dir/volume-$3" ] || exit 1; echo "[{\"configuration\":{\"name\":\"$3\",\"sizeInBytes\":$(cat "$dir/volume-$3")}}]" ;;
                  create) echo $(( ${4%M} * 1048576 )) > "$dir/volume-$5" ;;
                  delete) rm -f "$dir/volume-$3" ;;
                esac ;;
              run) name=""; prev=""; for a in "$@"; do [ "$prev" = "--name" ] && name="$a"; prev="$a"; done
                touch "$dir/running-$name"; echo "$name" ;;
              inspect) status=""; [ -f "$dir/running-$2" ] && status=running; [ -f "$dir/stopped-$2" ] && status=stopped
                [ -n "$status" ] || exit 1
                echo "[{\"status\":\"$status\",\"networks\":[{\"address\":\"127.0.0.1/24\"}],\"configuration\":{\"labels\":{}}}]" ;;
              start) [ -f "$dir/stopped-$2" ] || exit 1; mv "$dir/stopped-$2" "$dir/running-$2" ;;
              stop) [ -f "$dir/running-$2" ] || exit 1; mv "$dir/running-$2" "$dir/stopped-$2" ;;
              delete) rm -f "$dir/running-$3" "$dir/stopped-$3" ;;
              exec)
                shift; [ "$1" = "--interactive" ] && shift; shift
                if [ "$1" = rm ]; then rm -f "$dir/fs/$(echo "$3" | tr '/' '_')"; exit 0; fi
                case "$3" in
                  *'cat > "$1"'*) cat > "$dir/fs/$(echo "$5" | tr '/' '_')"; exit 0 ;;
                  *'getent hosts'*) [ -f "$dir/nonetwork" ] || printf 'dns\nreach\n'; exit 0 ;;
                esac
                PATH="$dir/bin:$PATH" exec "$@" ;;
            esac
            """#
        let server = #"""
            #!/bin/bash
            dir="$(cd "$(dirname "$0")/.." && pwd)"
            echo "visor-server $*" >> "$dir/calls"
            case "$1" in
              password) echo "$2" > "$dir/password" ;;
              start) port=""; prev=""; for a in "$@"; do [ "$prev" = "--port" ] && port="$a"; prev="$a"; done
                # The test's own server (FakeVisorServer) takes it from here.
                echo "$port" > "$dir/started" ;;
            esac
            """#
        try container.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        try server.write(to: folder.appendingPathComponent("bin/visor-server"), atomically: true, encoding: .utf8)
        for file in [path, folder.appendingPathComponent("bin/visor-server").path] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
        }
    }

    var calls: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// A file the host wrote in the container, by its path there.
    func written(_ path: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent("fs").appendingPathComponent(path.replacingOccurrences(of: "/", with: "_")),
                    encoding: .utf8)
    }

    func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The Visor server in the container, played here: once the fake
/// `visor-server start` has run (its port in `started`), a listener on
/// loopback that answers `/api/hello` and `/api/code` to the password the
/// fake `visor-server password` kept, and 401 to anyone else.
private final class FakeVisorServer: Sendable {
    let folder: URL
    private let listener = Mutex<Int32>(-1)
    private let ended = Mutex(false)

    init(folder: URL) {
        self.folder = folder
        Thread.detachNewThread { [self] in
            while !ended.withLock({ $0 }) {
                if let text = try? String(contentsOf: folder.appendingPathComponent("started"), encoding: .utf8),
                   let port = UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    serve(port)
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func serve(_ port: UInt16) {
        let socket = visor_listen(port, 0)
        guard socket >= 0 else { return }
        listener.withLock { $0 = socket }
        while true {
            let connection = visor_accept(socket)
            if connection < 0 { return }
            Thread.detachNewThread { [self] in answer(connection) }
        }
    }

    private func answer(_ connection: Int32) {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = buffer.withUnsafeMutableBytes { read(connection, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            request.append(contentsOf: buffer[0..<count])
        }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let password = (try? String(contentsOf: folder.appendingPathComponent("password"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authorized = lines.contains { $0.lowercased() == "authorization: bearer \(password)".lowercased() }
        let bodies = ["/api/hello": #"{"type":"hello","version":"0.45.0"}"#, "/api/code": #"{"type":"code","text":"visor-code"}"#]
        let body = authorized ? bodies[path] ?? #"{"type":"error"}"# : ""
        let response = "HTTP/1.1 \(authorized ? "200 OK" : "401 Unauthorized")\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body
        _ = Array(response.utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        close(connection)
    }

    func stop() {
        ended.withLock { $0 = true }
        let socket = listener.withLock { $0 }
        if socket >= 0 {
            visor_shutdown(socket)
            close(socket)
        }
    }
}

/// A port on loopback, likely free: from the high range, at random.
private func freePort() -> Int { Int.random(in: 20000...45000) }

/// What `curl` gets of `url` with the bearer `token`.
private func fetch(_ url: String, token: String) throws -> Data {
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-s", "-m", "10", "-H", "Authorization: Bearer \(token)", url]
    let out = Pipe()
    curl.standardOutput = out
    try curl.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    curl.waitUntilExit()
    return data
}

final class ServerHostTests: XCTestCase {
    private var fake: FakeServerTool!
    private var visor: FakeVisorServer!
    private var folder: URL!

    override func setUp() async throws {
        fake = try FakeServerTool()
        visor = FakeVisorServer(folder: fake.folder)
        folder = fake.folder.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        visor.stop()
        fake.remove()
    }

    private func host(listenPort: Int = 7440) throws -> ServerHost {
        var spec = ServerSpec(id: "S1", name: "Builds", image: "ghcr.io/example/agent:1")
        spec.cpus = 2
        spec.diskBytes = 16 << 30
        spec.mounts = [.init(source: "/Users/me/Developer", destination: "/Users/me/Developer", readOnly: false)]
        spec.listen.port = listenPort
        try JSONEncoder().encode(spec).write(to: folder.appendingPathComponent("server.json"))
        let read = try ServerSpec.read(folder)
        XCTAssertEqual(read, spec)
        var server = ContainerServer(spec: read, folder: folder, container: fake.tool, secrets: FileHostSecrets(folder: folder))
        server.serverPort = freePort()
        return ServerHost(server: server, clientHost: "127.0.0.1")
    }

    func testTheSpecReadsWithDefaults() throws {
        try Data(#"{"id": "abc", "image": "i"}"#.utf8).write(to: folder.appendingPathComponent("server.json"))
        let spec = try ServerSpec.read(folder)
        XCTAssertEqual(spec.name, "abc")
        XCTAssertEqual(spec.listen, ServerSpec.Listen())
        XCTAssertEqual(spec.containerName, "visor-server-abc")
    }

    func testBringingUpMakesTheContainerAndStartsItsServer() throws {
        let host = try host()
        XCTAssertNil(host.bringUp(patience: .seconds(20)))
        let run = try XCTUnwrap(fake.calls.first { $0.hasPrefix("run ") })
        XCTAssertTrue(run.contains("--volume visor-server-s1-home:/root"))
        XCTAssertTrue(run.contains("--volume visor-server-s1-build:/var/cache/bazel"))
        XCTAssertTrue(run.contains("--mount type=bind,source=/Users/me/Developer,target=/Users/me/Developer"))
        XCTAssertTrue(run.contains("--label visor.container-server=S1"))
        XCTAssertTrue(run.hasSuffix("ghcr.io/example/agent:1 sleep infinity"))
        // Its password on standard input, never on a command line.
        let password = try host.server.password()
        XCTAssertFalse(fake.calls.contains { $0.contains(password) && $0.hasPrefix("exec") })
        XCTAssertTrue(fake.calls.contains { $0.hasPrefix("visor-server start --port \(host.server.serverPort) --lan on --vpn on --ssh off --address http://127.0.0.1:7440") })
        XCTAssertTrue(host.answering())
        // Kept: asked again, the server is the same one.
        XCTAssertEqual(try host.server.password(), password)
        XCTAssertNil(host.bringUp(patience: .seconds(5)))
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("visor-server start") }.count, 1)
    }

    func testStatusSaysWhereClientsReachItAndItsCode() throws {
        let host = try host()
        XCTAssertEqual(host.status().state, "stopped")
        XCTAssertNil(host.bringUp(patience: .seconds(20)))
        let state = host.status()
        XCTAssertEqual(state.state, "ready")
        XCTAssertEqual(state.container, "visor-server-s1")
        XCTAssertEqual(state.server, .init(version: "0.45.0", answering: true))
        XCTAssertEqual(state.address, "http://127.0.0.1:7440")
        XCTAssertEqual(state.code, "visor-code")
    }

    func testCredentialsAreKeptAndWrittenIntoTheContainer() throws {
        let host = try host()
        let given = #"{"claudeToken": "sk-ant-oat", "openrouterKey": "or-key", "codexAuth": "\#(Data("{\"auth\":1}".utf8).base64EncodedString())", "mcpSecrets": {"gh Authorization": "Bearer gh"}}"#
        XCTAssertEqual(try host.credentials(Data(given.utf8)).sorted(), ["claudeToken", "codexAuth", "mcpSecrets", "openrouterKey"])
        XCTAssertEqual(host.server.secrets.value("mcp gh Authorization"), "Bearer gh")
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("secrets.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNil(host.bringUp(patience: .seconds(20)))
        XCTAssertEqual(fake.written("/root/.local/share/visor/agents/claude.env"), "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat\n")
        XCTAssertEqual(fake.written("/root/.local/share/visor/agents/openrouter.env"), "OPENROUTER_API_KEY=or-key\n")
        XCTAssertEqual(fake.written("/root/.codex/auth.json"), "{\"auth\":1}")

        // One left out stays; one given as null goes, there too.
        XCTAssertEqual(try host.credentials(Data(#"{"openrouterKey": null}"#.utf8)), ["openrouterKey"])
        XCTAssertEqual(host.server.secrets.value("claudeToken"), "sk-ant-oat")
        XCTAssertNil(host.server.secrets.value("openrouterKey"))
        XCTAssertNil(host.server.applyCredentials())
        XCTAssertNil(fake.written("/root/.local/share/visor/agents/openrouter.env"))
        XCTAssertNotNil(fake.written("/root/.local/share/visor/agents/claude.env"))
    }

    func testServePassesClientsOnAndLeavesTheContainerWhenEnded() throws {
        let port = freePort()
        let host = try host(listenPort: port)
        let stopped = Mutex(false)
        let ended = expectation(description: "serve ended")
        Thread.detachNewThread {
            host.serve(every: .milliseconds(200)) { stopped.withLock { $0 } }
            ended.fulfill()
        }
        // Ready, its state written down.
        let clock = ContinuousClock(), start = clock.now
        while ServerState.read(folder)?.state != "ready", clock.now - start < .seconds(30) { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(ServerState.read(folder)?.code, "visor-code")
        // A client through the host's port reaches the server.
        let hello = try fetch("http://127.0.0.1:\(port)/api/hello", token: try host.server.password())
        XCTAssertEqual((try JSONSerialization.jsonObject(with: hello) as? [String: Any])?["version"] as? String, "0.45.0")

        stopped.withLock { $0 = true }
        wait(for: [ended], timeout: 10)
        XCTAssertTrue(fake.has("running-visor-server-s1"), "the container left running")
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("stop ") || $0.hasPrefix("delete ") })
    }

    func testUpgradeMakesItAgainWithItsDisksAndRemoveTakesThemOnlyWhenAsked() throws {
        let host = try host()
        XCTAssertNil(host.bringUp(patience: .seconds(20)))
        XCTAssertTrue(fake.has("volume-visor-server-s1-home"))
        _ = host.upgrade()
        XCTAssertTrue(fake.calls.contains("delete --force visor-server-s1"))
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("volume delete") })
        XCTAssertTrue(fake.has("running-visor-server-s1"))
        host.server.remove(data: false)
        XCTAssertTrue(fake.has("volume-visor-server-s1-home"))
        host.server.remove(data: true)
        XCTAssertFalse(fake.has("volume-visor-server-s1-home"))
        XCTAssertFalse(fake.has("volume-visor-server-s1-build"))
    }

    func testANetworkThatIsGoneIsLost() throws {
        let host = try host()
        XCTAssertNil(host.bringUp(patience: .seconds(20)))
        let loopback = [HostAddresses.Address(interface: "lo", address: "127.0.0.1")]
        XCTAssertTrue(host.server.networkCheck(local: loopback).ok)
        // The containers' network made again under it: its address on none of this computer's.
        let elsewhere = host.server.networkCheck(local: [.init(interface: "bridge100", address: "192.168.65.1")])
        XCTAssertFalse(elsewhere.ok)
        XCTAssertTrue(elsewhere.detail.contains("on no network this computer has"))
        // Or nothing resolved from in it.
        _ = FileManager.default.createFile(atPath: fake.folder.appendingPathComponent("nonetwork").path, contents: nil)
        XCTAssertFalse(host.server.networkCheck(local: loopback).ok)
    }

    func testAServerThatDoesntAnswerOnALostNetworkIsMadeAgainWithItsDisks() throws {
        let host = try host()
        XCTAssertNil(host.bringUp(patience: .seconds(20)))
        // Answering: nothing to do.
        XCTAssertNil(host.remakeIfNetworkLost(local: [.init(interface: "lo", address: "127.0.0.1")]))
        // Not answering, its network gone: made again, its disks kept.
        visor.stop()
        let found = try XCTUnwrap(host.remakeIfNetworkLost(local: [.init(interface: "bridge100", address: "192.168.65.1")]))
        XCTAssertFalse(found.ok)
        XCTAssertTrue(fake.calls.contains("delete --force visor-server-s1"))
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("volume delete") })
        XCTAssertTrue(fake.has("volume-visor-server-s1-home"))
        XCTAssertEqual(host.server.state(), .missing)
    }

    func testTheClientHostIsTheLANsOrAVPNsElseLoopback() {
        let addresses: [HostAddresses.Address] = [.init(interface: "lo0", address: "127.0.0.1"), .init(interface: "bridge100", address: "192.168.64.1"),
                                                  .init(interface: "en0", address: "192.168.4.52"), .init(interface: "utun4", address: "100.90.45.11")]
        XCTAssertEqual(HostAddresses.clientHost(lan: true, vpn: true, from: addresses), "192.168.4.52")
        XCTAssertEqual(HostAddresses.clientHost(lan: false, vpn: true, from: addresses), "100.90.45.11")
        XCTAssertEqual(HostAddresses.clientHost(lan: false, vpn: false, from: addresses), "127.0.0.1")
    }

    func testTheCommandsTakeTheFolder() throws {
        _ = try host()
        let status = ContainerHostCommand.answer(["status", folder.path], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(status.status, 0)
        XCTAssertEqual(status.json["state"] as? String, "stopped")
        let kept = ContainerHostCommand.answer(["credentials", folder.path], input: Data(#"{"claudeToken": "t"}"#.utf8), container: fake.tool, version: "")
        XCTAssertEqual(kept.json["kept"] as? [String], ["claudeToken"])
        XCTAssertFalse(kept.text.contains("\"t\""), "values never echoed")
        let missing = ContainerHostCommand.answer(["status", "/no/such/folder"], input: Data(), container: fake.tool, version: "")
        XCTAssertEqual(missing.json["code"] as? String, "notFound")
    }
}
