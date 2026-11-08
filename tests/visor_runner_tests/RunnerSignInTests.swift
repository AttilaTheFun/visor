// Signing in to the Runner (docs/runner-accounts.md, step 2): its one user,
// set with its password from standard input and kept only as a hash, signs
// in for a session of the Runner's own, which lists the servers it serves
// and ends on signing out, when its time is up, or when the password
// changes. A wrong name or password, or no session, is told the same.

import Foundation
@testable import VisorRunner
import XCTest

final class RunnerSignInTests: XCTestCase {
    private var folder: URL!
    private var secrets: MemorySecrets!
    private var said: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runner-sign-in-\(UUID().uuidString)", isDirectory: true)
        secrets = MemorySecrets()
        said = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func run(_ arguments: [String], input: [String] = []) -> Int32 {
        var lines = input[...]
        return RunnerCommand(folder: folder, secrets: secrets, input: { lines.popFirst() }, output: { self.said.append($0) }).run(arguments)
    }

    private var api: RunnerAPI {
        let folder = folder!
        return RunnerAPI(auths: [RunnerPasswordAuth(user: { RunnerConfig.read(folder)?.user }, secrets: secrets)],
                         sessions: RunnerSessions(secrets: secrets),
                         servers: { RunnerServerInfo.listed(in: RunnerConfig.read(folder) ?? RunnerConfig()) })
    }

    private func signIn(_ username: String, _ password: String, now: Date = Date()) -> (status: Int, json: [String: Any]) {
        let body = try? JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let answer = api.answer(method: "POST", path: "/runner/v1/sign-in", authorization: nil, body: body ?? Data(), now: now)
        return (answer.status, ((try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any]) ?? [:])
    }

    private func servers(_ token: String?, now: Date = Date()) -> (status: Int, json: [String: Any]) {
        let answer = api.answer(method: "GET", path: "/runner/v1/servers", authorization: token.map { "Bearer \($0)" }, body: Data(), now: now)
        return (answer.status, ((try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any]) ?? [:])
    }

    func testThePasswordIsKeptAsAHashThatChecksIt() throws {
        let hash = try RunnerPassword.hash("correct horse battery")
        XCTAssertTrue(hash.hasPrefix("scrypt$32768$8$1$"), hash)
        XCTAssertFalse(hash.contains("correct horse"))
        XCTAssertTrue(RunnerPassword.verifies("correct horse battery", against: hash))
        XCTAssertFalse(RunnerPassword.verifies("correct horse batterY", against: hash))
        XCTAssertNotEqual(try RunnerPassword.hash("correct horse battery"), hash, "a salt of its own each time")
        XCTAssertFalse(RunnerPassword.verifies("x", against: "plain$text"))
        XCTAssertFalse(RunnerPassword.verifies("x", against: "scrypt$1099511627776$8$1$AAAA$AAAA"), "a cost past what's allowed")
    }

    func testTheUserSignsInAndSeesTheServers() throws {
        XCTAssertEqual(run(["server", "add", "mini", "--host", "127.0.0.1"]), 0)
        XCTAssertEqual(run(["server", "add", "co-tenant", "--host", "192.168.64.1"]), 0)
        XCTAssertEqual(run(["front", "set", "co-tenant", "--port", "7440", "--to", "192.168.64.5:7432"]), 0)
        XCTAssertEqual(run(["user", "set", "logan"], input: ["a long enough password"]), 0, said.joined(separator: "\n"))
        XCTAssertNil(secrets.all.values.first { $0.contains("a long enough password") }, "the password is never kept")

        let offered = api.answer(method: "GET", path: "/runner/v1/sign-in", authorization: nil, body: Data())
        XCTAssertEqual(String(decoding: offered.body, as: UTF8.self), #"{"providers":[{"kind":"password"}]}"#)

        let signed = signIn("logan", "a long enough password")
        XCTAssertEqual(signed.status, 200)
        XCTAssertEqual(signed.json["account"] as? String, "logan")
        let token = try XCTUnwrap(signed.json["token"] as? String)
        XCTAssertGreaterThanOrEqual(token.count, 40)
        XCTAssertNil(secrets.all.values.first { $0.contains(token) }, "a session is kept by its token's hash, never the token")

        let listed = servers(token)
        XCTAssertEqual(listed.status, 200)
        let names = (listed.json["servers"] as? [[String: Any]])?.map { "\($0["name"] ?? "") \($0["kind"] ?? "")" }
        XCTAssertEqual(names, ["mini mac", "co-tenant container"])

        // Signed out: the token is nothing.
        XCTAssertEqual(api.answer(method: "POST", path: "/runner/v1/sign-out", authorization: "Bearer \(token)", body: Data()).status, 200)
        XCTAssertEqual(servers(token).status, 401)
    }

    func testAWrongNameOrPasswordOrNoSessionIsToldTheSame() {
        XCTAssertEqual(run(["user", "set", "logan"], input: ["a long enough password"]), 0)
        let wrongPassword = signIn("logan", "not the password")
        let wrongName = signIn("someone", "a long enough password")
        let none = servers(nil)
        let made = servers("made-up")
        XCTAssertEqual([wrongPassword.status, wrongName.status, none.status, made.status], [401, 401, 401, 401])
        XCTAssertEqual(wrongPassword.json as NSDictionary, wrongName.json as NSDictionary)
        XCTAssertEqual(none.json as NSDictionary, wrongName.json as NSDictionary)
        XCTAssertNil(wrongPassword.json["token"])
    }

    func testASessionEndsWhenItsTimeIsUpOrThePasswordChanges() throws {
        XCTAssertEqual(run(["user", "set", "logan"], input: ["a long enough password"]), 0)
        let start = Date()
        let token = try XCTUnwrap(signIn("logan", "a long enough password", now: start).json["token"] as? String)
        XCTAssertEqual(servers(token, now: start.addingTimeInterval(29 * 24 * 60 * 60)).status, 200)
        XCTAssertEqual(servers(token, now: start.addingTimeInterval(31 * 24 * 60 * 60)).status, 401, "a month on")

        let again = try XCTUnwrap(signIn("logan", "a long enough password").json["token"] as? String)
        XCTAssertEqual(servers(again).status, 200)
        XCTAssertEqual(run(["user", "set", "logan"], input: ["another long password"]), 0)
        XCTAssertEqual(servers(again).status, 401, "a new password ends the sessions from before")
        XCTAssertEqual(signIn("logan", "a long enough password").status, 401)
        XCTAssertEqual(signIn("logan", "another long password").status, 200)

        XCTAssertEqual(run(["user", "remove"]), 0)
        XCTAssertEqual(signIn("logan", "another long password").status, 401, "no user: no one signs in")
    }

    /// Over the wire, as a client signs in: curl to the Runner's port, over
    /// TLS with the Runner's own certificate, which curl is shown to have met.
    func testAClientSignsInOverTLS() throws {
        XCTAssertEqual(run(["server", "add", "mini", "--host", "127.0.0.1"]), 0)
        XCTAssertEqual(run(["user", "set", "logan"], input: ["a long enough password"]), 0)
        let identity = try RunnerIdentity.kept(in: secrets, names: RunnerIdentity.names(given: []))
        var listening: RunnerAPIServer?
        var port: UInt16 = 0
        for _ in 0..<20 where listening == nil {
            port = UInt16.random(in: 20000...45000)
            listening = try RunnerAPIServer(port: port, api: api, identity: identity)
        }
        let server = try XCTUnwrap(listening)
        server.start()
        defer { server.stop() }
        let base = "https://127.0.0.1:\(port)/runner/v1"
        // The certificate the person compares, as a file, for curl to trust
        // and nothing else.
        let pem = folder.appendingPathComponent("runner.pem")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try identity.pem.write(to: pem, atomically: true, encoding: .utf8)

        let plain = try curl(["http://127.0.0.1:\(port)/runner/v1/sign-in"])
        XCTAssertNotEqual(plain.status, "200", "no plain HTTP")
        let untrusted = try curl([base + "/sign-in"])
        XCTAssertEqual(untrusted.status, "000", "a certificate no one has trusted is refused")

        let trust = ["--cacert", pem.path]
        let refused = try curl(trust + ["-X", "POST", "-H", "Content-Type: application/json",
                                        "-d", #"{"username":"logan","password":"wrong"}"#, base + "/sign-in"])
        XCTAssertEqual(refused.status, "401")
        let signed = try curl(trust + ["-X", "POST", "-H", "Content-Type: application/json",
                                       "-d", #"{"username":"logan","password":"a long enough password"}"#, base + "/sign-in"])
        XCTAssertEqual(signed.status, "200", signed.body)
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(signed.body.utf8)) as? [String: Any])?["token"] as? String)
        let listed = try curl(trust + ["-H", "Authorization: Bearer \(token)", base + "/servers"])
        XCTAssertEqual(listed.status, "200")
        XCTAssertEqual(listed.body, #"{"servers":[{"id":"mini","kind":"mac","name":"mini"}]}"#)
    }

    /// The Runner's certificate: made once and kept, the same fingerprint
    /// each time it is asked for, for its names; made again when they change.
    func testTheCertificateIsKeptForItsNames() throws {
        let names = RunnerIdentity.names(given: ["192.168.1.20", "mini.local"], host: "Logans-Mac-mini")
        XCTAssertEqual(names, ["localhost", "127.0.0.1", "::1", "Logans-Mac-mini", "192.168.1.20", "mini.local"])
        let first = try RunnerIdentity.kept(in: secrets, names: names)
        let fingerprint = try first.fingerprint
        XCTAssertEqual(fingerprint.split(separator: ":").count, 32)
        XCTAssertEqual(try RunnerIdentity.kept(in: secrets, names: names).fingerprint, fingerprint, "kept")
        XCTAssertEqual(RunnerIdentity.names(of: first.certificate), Set(names))
        XCTAssertNotEqual(try RunnerIdentity.kept(in: secrets, names: names + ["mini.tail.ts.net"]).fingerprint, fingerprint,
                          "a new name: a new certificate, which a client confirms again")
        let before = try RunnerIdentity.kept(in: secrets, names: names).fingerprint
        let soon = Date().addingTimeInterval(380 * 24 * 3600)
        XCTAssertNotEqual(try RunnerIdentity.kept(in: secrets, names: names, now: soon).fingerprint, before,
                          "made again within a month of its end")

        XCTAssertEqual(run(["api", "port", "7445", "--name", "192.168.1.20"]), 0)
        XCTAssertEqual(RunnerConfig.read(folder)?.apiNames, ["192.168.1.20"])
        XCTAssertEqual(run(["api", "certificate"]), 0)
        XCTAssertTrue(said.last?.hasPrefix("SHA-256 ") == true)
        XCTAssertTrue(said.last?.contains("-----BEGIN CERTIFICATE-----") == true)
        XCTAssertNil(said.last?.range(of: "PRIVATE KEY"), "never the key")
    }

    func testTheCommandsCheckWhatTheyAreGiven() {
        XCTAssertEqual(run(["user", "set", "logan"], input: ["short"]), 2, "a password of 12 characters at least")
        XCTAssertEqual(run(["user", "set", "lo gan"], input: ["a long enough password"]), 2)
        XCTAssertEqual(run(["api", "port", "7439"]), 2, "the MCP proxy's port")
        XCTAssertEqual(run(["api", "port", "7445"]), 0)
        XCTAssertEqual(RunnerConfig.read(folder)?.apiPort, 7445)
        XCTAssertEqual(run(["api", "port", "off"]), 0)
        XCTAssertNil(RunnerConfig.read(folder)?.apiPort)
        XCTAssertEqual(api.answer(method: "GET", path: "/runner/v1/other", authorization: nil, body: Data()).status, 404)
        XCTAssertEqual(api.answer(method: "POST", path: "/runner/v1/sign-in", authorization: nil, body: Data("nope".utf8)).status, 400)
    }
}
