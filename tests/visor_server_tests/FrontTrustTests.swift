// A server whose auth is `none`, behind a front with a sign-in of its own
// (docs/server-proxy.md, "Auth"): it lets in what the front vouches for,
// its token on the request or only the front reaching it, and takes the
// person from the headers it was told of; the front is given by the
// environment or the arguments, never by a name of one built in.

import Foundation
@testable import VisorServer
@testable import VisorServerCLI
import Testing

extension ServerTests {
@Suite @MainActor final class FrontTrustTests {
    private var server: VisorServer!
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("visor-front-trust-" + UUID().uuidString)

    init() async throws {
        TestPlatform.install()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        VisorServer.storeRoot = root
        VisorServer.secrets = MemorySecrets()
        server = VisorServer(port: ServerTestCase.freePort())
    }

    isolated deinit {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func request(_ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/api/sessions", headers: headers, body: "")
    }

    @Test func aTokensFrontLetsInOnlyWhatCarriesIt() {
        var settings = server.settings
        settings.authentication = "none"
        server.settings = settings
        #expect(server.authorized(request([:])), "no front told of: whatever reaches it")
        server.front = FrontTrust(trust: .token(header: "Front-Token", value: "front-secret-0123"))
        #expect(server.authorized(request(["front-token": "front-secret-0123"])))
        #expect(!server.authorized(request(["front-token": "front-secret-0124"])))
        #expect(!server.authorized(request(["front-token": "front-secret-012"])))
        #expect(!server.authorized(request([:])))
        var trusted = request([:])
        trusted.trusted = true
        #expect(server.authorized(trusted), "the socket file, as ever")
        server.front = FrontTrust(trust: .listener)
        #expect(server.authorized(request([:])))
    }

    @Test func aFrontsWordIsTakenOnlyWhenTheServerAsksNothing() {
        server.front = FrontTrust(trust: .listener)
        #expect(server.settings.authentication == "password")
        #expect(!server.authorized(request([:])), "a password's server still wants its password")
    }

    @Test func thePersonComesFromTheHeadersItWasToldOf() {
        let front = FrontTrust(trust: .listener, userHeader: "X-Forwarded-User", userNameHeader: "X-Forwarded-Name",
                               deviceHeader: "X-Device")
        let named = front.person(["x-forwarded-user": "github:583231", "x-forwarded-name": "octocat", "x-device": "Test iPhone"])
        #expect(named.id == "github:583231")
        #expect(named.name == "octocat")
        #expect(named.device == "Test iPhone")
        #expect(front.person([:]).id == "owner")
        #expect(FrontTrust(trust: .listener).person(["x-forwarded-user": "someone"]).id == "owner", "no header told of: owner")
        #expect(FrontTrust.same(Array("abc".utf8), Array("abc".utf8)))
        #expect(!FrontTrust.same(Array("abd".utf8), Array("abc".utf8)))
        #expect(!FrontTrust.same([], []), "no token is never a match")
    }

    @Test func theFrontIsGivenByTheEnvironmentOrTheArguments() throws {
        let file = root.appendingPathComponent("front.token")
        try "front-secret-0123\n".write(to: file, atomically: true, encoding: .utf8)
        let options = try ServerOptions([], environment: ["VISOR_TRUST": "token", "VISOR_TRUST_HEADER": "MultiPass-Backend",
                                                          "VISOR_TRUST_TOKEN_FILE": file.path, "VISOR_USER_HEADER": "MultiPass-User-ID",
                                                          "VISOR_USER_NAME_HEADER": "MultiPass-User"])
        let front = try #require(try options.front)
        #expect(front.trust == .token(header: "MultiPass-Backend", value: "front-secret-0123"))
        #expect(front.userHeader == "MultiPass-User-ID")
        #expect(options.settings.contains { $0 == ("auth", "none") }, "a front means auth none")
        #expect(!options.arguments.contains("front-secret-0123"), "the token goes on as its file")
        #expect(try ServerOptions(options.arguments).front == front, "a run started from this one has the same front")
        #expect(try ServerOptions(["--trust", "listener", "--user-header", "X-Forwarded-User"]).front?.trust == .listener)
        #expect(throws: (any Error).self) { try ServerOptions(["--trust", "token"]) }
        #expect(throws: (any Error).self) { try ServerOptions(["--trust", "sometimes"]) }
        #expect(throws: (any Error).self) { try ServerOptions(["--user-header", "X-Forwarded-User"]) }
        #expect(try ServerOptions([]).front == nil)
    }
}
}
