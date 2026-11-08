// A server's API through the Runner (docs/runner-accounts.md, step 4):
// a signed-in client's request for `/runner/v1/servers/<id>/<path>` reaches
// that server as `/<path>`, with the server's password in place of the
// client's session, and its answer comes back. Without a session, or for a
// server the Runner doesn't reach, nothing reaches any server.

import CVisorPOSIX
import Foundation
import Synchronization
@testable import VisorRunner
import XCTest

final class RunnerProxyTests: XCTestCase {
    private var folder: URL!
    private var secrets: MemorySecrets!

    /// A stand-in Visor server: what it was asked, and an answer of its own.
    final class StandIn: Sendable {
        let port: UInt16
        private let listener: Int32
        let heard = Mutex<[(path: String, authorization: String?, body: String)]>([])

        init?() {
            var found: (UInt16, Int32)?
            for _ in 0..<20 where found == nil {
                let port = UInt16.random(in: 20000...45000)
                let listener = visor_listen(port, 0)
                if listener >= 0 { found = (port, listener) }
            }
            guard let found else { return nil }
            (port, listener) = found
            Thread.detachNewThread { [self] in
                while true {
                    let client = visor_accept(listener)
                    if client < 0 { return }
                    if let request = MCPProxy.read(client) {
                        heard.withLock { $0.append((request.path, request.header("authorization"), String(decoding: request.body, as: UTF8.self))) }
                        if request.header("upgrade")?.lowercased() == "websocket" {
                            // Its own 101, then whatever comes, back with a word.
                            MCPProxy.send(client, Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                + "Sec-WebSocket-Accept: \(request.header("sec-websocket-key") ?? "")\r\n\r\n").utf8))
                            var buffer = [UInt8](repeating: 0, count: 4096)
                            while true {
                                let count = buffer.withUnsafeMutableBytes { Foundation.read(client, $0.baseAddress, $0.count) }
                                if count <= 0 { break }
                                MCPProxy.send(client, Data("echo:".utf8) + Data(buffer[0..<count]))
                            }
                            close(client)
                            continue
                        }
                        let body = Data(#"{"sessions":[]}"#.utf8)
                        MCPProxy.send(client, Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
                    }
                    close(client)
                }
            }
        }

        func stop() {
            visor_shutdown(listener)
            close(listener)
        }
    }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-proxy-\(UUID().uuidString)", isDirectory: true)
        secrets = MemorySecrets()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ arguments: [String], input: [String] = []) -> Int32 {
        var lines = input[...]
        return RunnerCommand(folder: folder, secrets: secrets, input: { lines.popFirst() }, output: { _ in }).run(arguments)
    }

    func testASignedInClientReachesTheServerWithItsPassword() throws {
        let standIn = try XCTUnwrap(StandIn())
        defer { standIn.stop() }
        XCTAssertEqual(run(["server", "add", "mini", "--host", "127.0.0.1"]), 0)
        XCTAssertEqual(run(["server", "reach", "mini", "--at", "127.0.0.1:\(standIn.port)"], input: ["the-servers-password"]), 0)
        XCTAssertEqual(run(["server", "add", "gone", "--host", "127.0.0.1"]), 0)
        XCTAssertEqual(run(["server", "reach", "gone", "--at", "127.0.0.1:1"], input: ["x"]), 0)
        XCTAssertEqual(run(["user", "set", "logan"], input: ["a long enough password"]), 0)
        XCTAssertNil(secrets.all.first { $0.key.hasPrefix("server password") && !$0.value.isEmpty && $0.key != "server password mini" && $0.key != "server password gone" })

        let folder = folder!, secrets = secrets!
        let api = RunnerAPI(auths: [RunnerPasswordAuth(user: { RunnerConfig.read(folder)?.user }, secrets: secrets)],
                            sessions: RunnerSessions(secrets: secrets),
                            servers: { RunnerServerInfo.listed(in: RunnerConfig.read(folder) ?? RunnerConfig()) })
        let identity = try RunnerIdentity.kept(in: secrets, names: RunnerIdentity.names(given: []))
        var listening: RunnerAPIServer?
        var port: UInt16 = 0
        for _ in 0..<20 where listening == nil {
            port = UInt16.random(in: 20000...45000)
            listening = try RunnerAPIServer(port: port, api: api, identity: identity,
                                            reach: { RunnerCommand.reach($0, folder: folder, secrets: secrets) })
        }
        let runner = try XCTUnwrap(listening)
        runner.start()
        defer { runner.stop() }
        let pem = folder.appendingPathComponent("runner.pem")
        try identity.pem.write(to: pem, atomically: true, encoding: .utf8)
        let base = "https://127.0.0.1:\(port)/runner/v1"
        let trust = ["--cacert", pem.path]

        // Not signed in: nothing reaches the server.
        let refused = try curl(trust + [base + "/servers/mini/api/sessions"])
        XCTAssertEqual(refused.status, "401")
        XCTAssertTrue(standIn.heard.withLock { $0.isEmpty })

        let signed = try curl(trust + ["-X", "POST", "-H", "Content-Type: application/json",
                                       "-d", #"{"username":"logan","password":"a long enough password"}"#, base + "/sign-in"])
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(signed.body.utf8)) as? [String: Any])?["token"] as? String)
        let bearer = ["-H", "Authorization: Bearer \(token)"]

        let listed = try curl(trust + bearer + [base + "/servers/mini/api/sessions?archived=1"])
        XCTAssertEqual(listed.status, "200")
        XCTAssertEqual(listed.body, #"{"sessions":[]}"#)
        let sent = try curl(trust + bearer + ["-X", "POST", "-H", "Content-Type: application/json", "-d", #"{"text":"hi"}"#,
                                              base + "/servers/mini/api/sessions/A/send"])
        XCTAssertEqual(sent.status, "200")
        let heard = standIn.heard.withLock { $0 }
        XCTAssertEqual(heard.map(\.path), ["/api/sessions?archived=1", "/api/sessions/A/send"])
        XCTAssertEqual(heard.map(\.authorization), ["Bearer the-servers-password", "Bearer the-servers-password"],
                       "the server's password, never the client's session")
        XCTAssertEqual(heard.last?.body, #"{"text":"hi"}"#)

        XCTAssertEqual(try curl(trust + bearer + [base + "/servers/nowhere/api/sessions"]).status, "404")
        XCTAssertEqual(try curl(trust + bearer + [base + "/servers/gone/api/sessions"]).status, "502")
        XCTAssertEqual(standIn.heard.withLock { $0.count }, 2, "nothing more reached the server")

        // A WebSocket: its upgrade goes on with the server's password, the
        // server's own 101 comes back, then bytes go each way as they are.
        let script = """
        import socket, ssl, sys
        context = ssl.create_default_context(cafile=sys.argv[1])
        context.check_hostname = False
        with socket.create_connection(("127.0.0.1", int(sys.argv[2]))) as raw:
            with context.wrap_socket(raw) as s:
                s.sendall(("GET /runner/v1/servers/mini/api/channel HTTP/1.1\\r\\nHost: runner\\r\\nConnection: Upgrade\\r\\n"
                           "Upgrade: websocket\\r\\nSec-WebSocket-Version: 13\\r\\nSec-WebSocket-Key: dGhlIGtleQ==\\r\\n"
                           "Authorization: Bearer " + sys.argv[3] + "\\r\\n\\r\\n").encode())
                answer = b""
                while b"\\r\\n\\r\\n" not in answer:
                    answer += s.recv(4096)
                head, _, rest = answer.partition(b"\\r\\n\\r\\n")
                print(head.split(b"\\r\\n")[0].decode())
                print([line.decode() for line in head.split(b"\\r\\n") if line.lower().startswith(b"sec-websocket-accept")][0])
                s.sendall(b"frame-one")
                got = rest
                while len(got) < len(b"echo:frame-one"):
                    got += s.recv(4096)
                print(got.decode())
        """
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", "-I", "-c", script, pem.path, String(port), token]
        let out = Pipe()
        python.standardOutput = out
        try python.run()
        let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        python.waitUntilExit()
        XCTAssertEqual(said, "HTTP/1.1 101 Switching Protocols\nSec-WebSocket-Accept: dGhlIGtleQ==\necho:frame-one\n")
        let upgrade = standIn.heard.withLock { $0.last }
        XCTAssertEqual(upgrade?.path, "/api/channel")
        XCTAssertEqual(upgrade?.authorization, "Bearer the-servers-password", "the server's password, never the session")
    }
}
