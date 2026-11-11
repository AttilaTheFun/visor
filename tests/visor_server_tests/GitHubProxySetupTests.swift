// The GitHub proxy's setup in the server (docs/github-proxy.md, rollout step
// 4): set over REST with the password, never an agent's token; on for the
// sessions named (one first, then `*`); an agent of such a session started
// with HTTPS_PROXY naming its server's token, the session and its
// repository, gh's placeholder token, and the proxy's authority trusted
// beside the system's own. A session it isn't on for is started as before.

import Foundation
import VisorProtocol
@testable import VisorServer
import XCTest

@MainActor
final class GitHubProxySetupTests: ServerTestCase {
    private var server: VisorServer!
    private var root: URL!
    private let authority = "-----BEGIN CERTIFICATE-----\nMIIBproxy\n-----END CERTIFICATE-----\n"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-github-proxy-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: Self.freePort())
        server.password = "pw"
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func set(_ body: [String: Any], bearer: String = "pw") -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return server.route(HTTPRequest(method: "PUT", path: "/api/github-proxy", headers: ["authorization": "Bearer " + bearer],
                                        body: String(decoding: data, as: UTF8.self)))
    }

    /// A checkout of AttilaTheFun/shireworks, its config as git writes it.
    private func checkout() throws -> String {
        let folder = root.appendingPathComponent("shireworks/Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("shireworks/.git/config")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://github.com/AttilaTheFun/shireworks.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n".utf8)
            .write(to: config)
        return folder.path
    }

    func testItIsSetWithThePasswordNeverAnAgentsToken() {
        XCTAssertEqual(set(["url": "http://192.168.131.1:7441", "token": "tok"], bearer: server.agentToken).status, 403)
        XCTAssertEqual(set(["url": "http://192.168.131.1:7441", "token": "tok", "authority": authority, "sessions": ["S"]]).status, 200)
        XCTAssertEqual(server.settings.githubProxy, "http://192.168.131.1:7441")
        XCTAssertEqual(server.settings.githubProxySessions, ["S"])
        let read = server.route(HTTPRequest(method: "GET", path: "/api/github-proxy", headers: ["authorization": "Bearer pw"], body: ""))
        XCTAssertTrue(read.body.contains("\"kept\":true") && read.body.contains("\"authority\":true") && !read.body.contains("tok"), read.body)
        XCTAssertEqual(set(["url": "github.com"]).status, 400, "an http://host:port address")
        XCTAssertEqual(set(["url": ""]).status, 200)
        XCTAssertNil(VisorServer.secrets.get(VisorServer.githubProxyTokenKey), "no proxy, no token")
    }

    func testAnAgentOfASessionItIsOnForGoesThroughIt() throws {
        XCTAssertEqual(set(["url": "http://192.168.131.1:7441", "token": "tok", "authority": authority, "sessions": ["S"]]).status, 200)
        let environment = server.githubProxyEnvironment(for: SessionInfo(id: "S", agent: .claude, cwd: try checkout(), title: "S", created: 0))
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://tok:S%40AttilaTheFun%2Fshireworks@192.168.131.1:7441")
        XCTAssertEqual(environment["GH_TOKEN"], VisorServer.githubPlaceholderToken)
        let bundle = try XCTUnwrap(environment["SSL_CERT_FILE"])
        XCTAssertEqual(environment["GIT_SSL_CAINFO"], bundle)
        XCTAssertTrue(try String(contentsOfFile: bundle, encoding: .utf8).hasSuffix(authority), "the system's authorities, then the proxy's")
        XCTAssertEqual(try String(contentsOfFile: try XCTUnwrap(environment["NODE_EXTRA_CA_CERTS"]), encoding: .utf8), authority)
        // Not a session it is on for.
        XCTAssertEqual(server.githubProxyEnvironment(for: SessionInfo(id: "T", agent: .claude, cwd: "/tmp", title: "T", created: 0)), [:])
        // Every session, once it is on for `*`; one in no checkout names none.
        XCTAssertEqual(set(["url": "http://192.168.131.1:7441", "sessions": ["*"]]).status, 200)
        XCTAssertEqual(server.githubProxyEnvironment(for: SessionInfo(id: "T", agent: .claude, cwd: root.path, title: "T", created: 0))["HTTPS_PROXY"],
                       "http://tok:T@192.168.131.1:7441")
    }

    func testACheckoutsRepositoryIsReadFromItsConfig() throws {
        XCTAssertEqual(GitHubRepository.ofCheckout(folder: try checkout()), "AttilaTheFun/shireworks")
        XCTAssertNil(GitHubRepository.ofCheckout(folder: "/"))
    }
}
