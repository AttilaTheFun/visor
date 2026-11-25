// The GitHub App's installation tokens (0.71.1, a choice beside Settings'
// auth token): its JWT (RS256, the App its issuer, a signature its key's
// public half verifies), its installation found by the gate's owner, a token
// minted for the gate's repositories with its permissions, kept until five
// minutes before it expires, one mint for requests that come together, the
// App before the auth token only when its key and id are both kept, each
// failure said, and no key, JWT or token in a log line or a refusal. GitHub
// is a stand-in, and the App's key is made here, never a real one.

import Foundation
import Testing
import _CryptoExtras
@testable import VisorAgentProxy

/// The App's key, made for these tests: 2048 bits, as GitHub's are.
private let testKey: _RSA.Signing.PrivateKey = {
    do { return try _RSA.Signing.PrivateKey(keySize: .bits2048) } catch { fatalError("no RSA key could be made: \(error)") }
}()

/// A clock a test moves.
private final class TestClock: Sendable {
    private let time = Locked(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

/// GitHub's API, as the App calls it, played: the App's installations
/// listed a page at a time, and each installation's token minted (or either
/// refused); every call kept.
private final class StandInGitHub: GitHubAppCalling {
    struct Call: Sendable {
        let method: String
        let path: String
        let jwt: String
        let body: Data?
        var line: String { "\(method) \(path)" }
    }

    private let installations: [(id: Int, login: String)]
    private let listing: (status: Int, message: String)?
    private let minting: (status: Int, message: String)?
    private let lifetime: TimeInterval
    private let delay: Duration
    private let now: @Sendable () -> Date
    private let heard = Locked<[Call]>([])
    private let count = Locked(0)

    init(installations: [(id: Int, login: String)], listing: (status: Int, message: String)? = nil,
         minting: (status: Int, message: String)? = nil, lifetime: TimeInterval = 3600, delay: Duration = .zero,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.installations = installations
        self.listing = listing
        self.minting = minting
        self.lifetime = lifetime
        self.delay = delay
        self.now = now
    }

    var calls: [Call] { heard.withLock { $0 } }
    var lines: [String] { calls.map(\.line) }
    /// How many tokens were minted.
    var minted: Int { count.withLock { $0 } }

    func call(_ method: String, _ path: String, jwt: String, body: Data?) async throws -> (status: Int, body: Data) {
        heard.withLock { $0.append(Call(method: method, path: path, jwt: jwt, body: body)) }
        if method == "GET", path.hasPrefix("/app/installations?") {
            if let listing { return (listing.status, Self.json(["message": listing.message])) }
            let query = URLComponents(string: path)?.queryItems ?? []
            let perPage = Int(query.first { $0.name == "per_page" }?.value ?? "") ?? 30
            let page = Int(query.first { $0.name == "page" }?.value ?? "") ?? 1
            let listed = installations.dropFirst((page - 1) * perPage).prefix(perPage)
            return (200, Self.json(listed.map { ["id": $0.id, "account": ["login": $0.login]] as [String: Any] }))
        }
        if method == "POST", path.hasPrefix("/app/installations/"), path.hasSuffix("/access_tokens") {
            if delay > .zero { try await Task.sleep(for: delay) }
            if let minting { return (minting.status, Self.json(["message": minting.message])) }
            let number = count.withLock { (value: inout Int) -> Int in
                value += 1
                return value
            }
            let expires = ISO8601DateFormatter().string(from: now().addingTimeInterval(lifetime))
            return (201, Self.json(["token": "ghs_minted\(number)", "expires_at": expires]))
        }
        return (404, Self.json(["message": "Not Found"]))
    }

    static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }
}

/// What a mint asked for.
private struct MintBody: Decodable {
    let repositories: [String]?
    let permissions: [String: String]
}

/// base64url, read.
private func unbase64URL(_ text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}

@Suite struct GitHubAppTokensTests {
    private func secrets(key: String = testKey.pemRepresentation, id: String = "123456", installation: String? = nil) throws -> GitHubAppSecrets {
        try #require(GitHubAppSecrets(key: key, id: id, installation: installation))
    }

    @Test func theJWTIsRS256ByTheAppAndItsSignatureVerifies() throws {
        let pkcs1 = testKey.pemRepresentation
        let pkcs8 = testKey.pkcs8PEMRepresentation
        #expect(pkcs1.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"), "PKCS #1, as GitHub issues it")
        #expect(pkcs8.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        struct Header: Decodable, Equatable {
            let alg: String
            let typ: String
        }
        struct Claims: Decodable {
            let iat: Int
            let exp: Int
            let iss: Int
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000.7)
        for pem in [pkcs1, pkcs8] {
            let key = try #require(GitHubAppJWT.key(pem: pem))
            let jwt = try GitHubAppJWT.make(appID: "123456", key: key, now: now)
            let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            try #require(parts.count == 3)
            #expect(!jwt.contains("=") && !jwt.contains("+") && !jwt.contains("/"), "base64url, unpadded")
            let header = try JSONDecoder().decode(Header.self, from: try #require(unbase64URL(parts[0])))
            #expect(header == Header(alg: "RS256", typ: "JWT"))
            let claims = try JSONDecoder().decode(Claims.self, from: try #require(unbase64URL(parts[1])))
            #expect(claims.iat == 1_800_000_000 - 60, "a minute ago: clocks drift")
            #expect(claims.exp == 1_800_000_000 + 9 * 60, "nine minutes on: GitHub takes ten at most")
            #expect(claims.iss == 123456, "the App's id, a number")
            let signature = _RSA.Signing.RSASignature(rawRepresentation: try #require(unbase64URL(parts[2])))
            let signed = Data((parts[0] + "." + parts[1]).utf8)
            #expect(testKey.publicKey.isValidSignature(signature, for: signed, padding: .insecurePKCS1v1_5), "RSASSA-PKCS1-v1_5, SHA-256")
            #expect(!testKey.publicKey.isValidSignature(signature, for: signed + Data("x".utf8), padding: .insecurePKCS1v1_5))
        }
        // A client id is the issuer as a string.
        struct Issuer: Decodable { let iss: String }
        let byClient = try GitHubAppJWT.make(appID: "Iv1.abc", key: testKey, now: now).split(separator: ".").map(String.init)
        #expect(try JSONDecoder().decode(Issuer.self, from: try #require(unbase64URL(byClient[1]))).iss == "Iv1.abc")
        #expect(GitHubAppJWT.key(pem: "not a key") == nil)
        #expect(GitHubAppJWT.key(pem: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----") == nil)
    }

    @Test func theInstallationIsTheGateOwnersFoundOnceAndSaid() async throws {
        let lines = Lines()
        // Past the first page, its login in another case.
        let listed = (1...130).map { (id: $0, login: "someone-\($0)") } + [(id: 4242, login: "attilathefun")]
        let github = StandInGitHub(installations: listed)
        let tokens = GitHubAppTokens(rules: .standard, api: github, log: { lines.add($0) })
        #expect(try await tokens.token(secrets()) == "ghs_minted1")
        #expect(github.lines == ["GET /app/installations?per_page=100&page=1", "GET /app/installations?per_page=100&page=2",
                                 "POST /app/installations/4242/access_tokens"])
        _ = try await tokens.token(secrets())
        #expect(github.calls.count == 3, "the installation and its token kept")
        #expect(lines.all.contains("github: tokens minted as the GitHub App 123456 (installation 4242 of AttilaTheFun), hourly, "
                                   + "for all of AttilaTheFun's"), "\(lines.all)")
        // Every call is the App's: a JWT of its id, signed with its key.
        for call in github.calls {
            let parts = call.jwt.split(separator: ".").map(String.init)
            try #require(parts.count == 3)
            let signature = _RSA.Signing.RSASignature(rawRepresentation: try #require(unbase64URL(parts[2])))
            #expect(testKey.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8), padding: .insecurePKCS1v1_5))
        }
        // Named by the secrets: not looked for.
        let named = StandInGitHub(installations: [])
        let direct = GitHubAppTokens(rules: .standard, api: named, log: { _ in })
        #expect(try await direct.token(secrets(installation: "77")) == "ghs_minted1")
        #expect(named.lines == ["POST /app/installations/77/access_tokens"])
    }

    @Test func aTokenIsMintedForTheGatesRepositoriesWithItsPermissions() async throws {
        var rules = GateRules.standard
        rules.repositories = ["AttilaTheFun/visor", "AttilaTheFun/shireworks", "someone/else"]
        let github = StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")])
        let lines = Lines()
        let tokens = GitHubAppTokens(rules: rules, api: github, log: { lines.add($0) })
        _ = try await tokens.token(secrets())
        let mint = try #require(github.calls.last)
        #expect(mint.line == "POST /app/installations/42/access_tokens")
        let body = try JSONDecoder().decode(MintBody.self, from: try #require(mint.body))
        #expect(body.repositories == ["visor", "shireworks"], "the owner's the rules list, by name")
        #expect(body.permissions == rules.tokenPermissions)
        #expect(lines.all.contains { $0.hasSuffix("(installation 42 of AttilaTheFun), hourly, for visor, shireworks") }, "\(lines.all)")
        // Every one of the owner's: none named, so the token reaches what the installation does.
        let everyRepository = StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")])
        _ = try await GitHubAppTokens(rules: .standard, api: everyRepository, log: { _ in }).token(secrets())
        let all = try #require(everyRepository.calls.last?.body)
        #expect(!String(decoding: all, as: UTF8.self).contains("repositories"))
        #expect(try JSONDecoder().decode(MintBody.self, from: all).permissions == GateRules.standard.tokenPermissions)
    }

    @Test func theTokenIsKeptUntilFiveMinutesBeforeItExpires() async throws {
        let clock = TestClock()
        let start = clock.now
        let github = StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")], lifetime: 3600, now: { clock.now })
        let lines = Lines()
        let tokens = GitHubAppTokens(rules: .standard, api: github, now: { clock.now }, log: { lines.add($0) })
        #expect(try await tokens.token(secrets()) == "ghs_minted1")
        #expect(lines.all.contains("github: an installation token minted (expires \(ISO8601DateFormatter().string(from: start + 3600)))"),
                "\(lines.all)")
        clock.advance(3600 - 301)
        #expect(try await tokens.token(secrets()) == "ghs_minted1", "301 seconds left: kept")
        clock.advance(2)
        #expect(try await tokens.token(secrets()) == "ghs_minted2", "299 left: minted again")
        #expect(try await tokens.token(secrets()) == "ghs_minted2")
        // GitHub turned it down: the next request mints another.
        await tokens.forget()
        #expect(try await tokens.token(secrets()) == "ghs_minted3")
        #expect(github.lines.filter { $0.hasPrefix("GET") }.count == 1, "the installation found once")
        #expect(github.minted == 3)
        // Other secrets: what was found and minted is forgotten.
        #expect(try await tokens.token(secrets(installation: "43")) == "ghs_minted4")
        #expect(github.lines.last == "POST /app/installations/43/access_tokens")
        #expect(lines.all.contains { $0.contains("(installation 43 of AttilaTheFun)") }, "said again: the secrets changed")
    }

    @Test func requestsThatComeTogetherShareOneMint() async throws {
        let github = StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")], delay: .milliseconds(300))
        let tokens = GitHubAppTokens(rules: .standard, api: github, log: { _ in })
        let kept = try secrets()
        let got = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await tokens.token(kept) } }
            var all: [String] = []
            for try await token in group { all.append(token) }
            return all
        }
        #expect(got.count == 20 && Set(got) == ["ghs_minted1"])
        #expect(github.minted == 1)
        #expect(github.lines.filter { $0.hasPrefix("GET") }.count == 1)
    }

    @Test func theAppComesBeforeTheAuthTokenOnlyWithItsKeyAndId() async throws {
        let kept = Locked<[String: String]>([:])
        let github = StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")])
        let source = PreferredGitHubToken(
            app: GitHubAppTokens(rules: .standard, api: github, log: { _ in }),
            appSecrets: { kept.withLock { GitHubAppSecrets(key: $0["key"], id: $0["id"], installation: $0["installation"]) } },
            configured: ConfiguredGitHubToken(current: { kept.withLock { $0["token"] } }))
        // Neither: the usual refusal.
        await #expect(throws: (any Error).self) { try await source.token(session: "s", repository: "o/r") }
        kept.withLock { $0["token"] = "github_pat_static" }
        #expect(try await source.token(session: "s", repository: "o/r") == "github_pat_static")
        let pem = testKey.pemRepresentation
        kept.withLock { $0["key"] = pem }
        #expect(try await source.token(session: "s", repository: "o/r") == "github_pat_static", "the key without the id: not the App")
        kept.withLock { (values: inout [String: String]) in
            values["key"] = nil
            values["id"] = "123456"
            values["installation"] = "42"
        }
        #expect(try await source.token(session: "s", repository: "o/r") == "github_pat_static", "the id without the key: not the App")
        kept.withLock { $0["key"] = pem }
        #expect(try await source.token(session: "s", repository: "o/r") == "ghs_minted1", "both: the App's, over the auth token")
        kept.withLock { $0["token"] = nil }
        #expect(try await source.token(session: "s", repository: "o/r") == "ghs_minted1")
        #expect(github.minted == 1)
        #expect(GitHubAppSecrets(key: " \n", id: "1") == nil, "a blank one is none")
        let blankInstallation = try #require(GitHubAppSecrets(key: pem, id: "1", installation: " "))
        #expect(blankInstallation.installation == nil)
    }

    @Test func eachFailureSaysWhyInTheLogAndTheRefusal() async throws {
        let lines = Lines()
        let github = StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")])
        let notAKey = try secrets(key: "not a key")
        let broken = GitHubAppTokens(rules: .standard, api: github, log: { lines.add($0) })
        await #expect(throws: GitHubAppTokens.Failure(why: "the App's key isn't a PEM")) { try await broken.token(notAKey) }
        _ = try? await broken.token(notAKey)
        #expect(lines.all == ["github: the App's key isn't a PEM"], "said once until it changes")
        #expect(github.calls.isEmpty, "nothing asked of GitHub without a key")
        do {
            _ = try await broken.token(notAKey)
            Issue.record("no key: no token")
        } catch {
            #expect("\(error)" == "agent-proxy has no auth token for GitHub: the App's key isn't a PEM", "the gate's refusal, saying why")
        }

        let elsewhere = StandInGitHub(installations: [(id: 7, login: "someone-else")])
        let unfound = GitHubAppTokens(rules: .standard, api: elsewhere, log: { lines.add($0) })
        let good = try secrets()
        await #expect(throws: GitHubAppTokens.Failure(why: "no installation of the App for AttilaTheFun")) { try await unfound.token(good) }
        #expect(lines.all.last == "github: no installation of the App for AttilaTheFun")

        let refusing = StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")], minting: (422, "Validation Failed"))
        let refused = GitHubAppTokens(rules: .standard, api: refusing, log: { lines.add($0) })
        await #expect(throws: GitHubAppTokens.Failure(why: "GitHub answered 422 minting a token: Validation Failed")) {
            try await refused.token(good)
        }
        #expect(lines.all.last == "github: GitHub answered 422 minting a token: Validation Failed")

        let unlisted = StandInGitHub(installations: [], listing: (401, "A JSON web token could not be decoded"))
        let unauthorized = GitHubAppTokens(rules: .standard, api: unlisted, log: { lines.add($0) })
        await #expect(throws: GitHubAppTokens.Failure.self) { try await unauthorized.token(good) }
        #expect(lines.all.last == "github: GitHub answered 401 listing the App's installations: A JSON web token could not be decoded")

        let numbered = GitHubAppTokens(rules: .standard, api: github, log: { lines.add($0) })
        let misnamed = try secrets(installation: "forty-two")
        await #expect(throws: GitHubAppTokens.Failure.self) { try await numbered.token(misnamed) }
        #expect(lines.all.last == "github: the App's installation (github-app/installation) isn't a number")
    }

    @Test func noLogLineOrRefusalHoldsTheKeyAJWTOrAToken() async throws {
        let lines = Lines()
        let clock = TestClock()
        let github = StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")], now: { clock.now })
        let tokens = GitHubAppTokens(rules: .standard, api: github, now: { clock.now }, log: { lines.add($0) })
        var said: [String] = []
        var minted: [String] = []
        for pem in [testKey.pemRepresentation, testKey.pkcs8PEMRepresentation] {
            let app = try secrets(key: pem)
            said += ["\(app)", String(reflecting: app)]
            await tokens.prepare(app)
            minted.append(try await tokens.token(app))
            clock.advance(3600)
            minted.append(try await tokens.token(app))
        }
        let failing = GitHubAppTokens(rules: .standard, api: StandInGitHub(installations: [(id: 42, login: "AttilaTheFun")],
                                                                           minting: (403, "Resource not accessible by integration")),
                                      log: { lines.add($0) })
        let good = try secrets()
        do { _ = try await failing.token(good) } catch { said.append("\(error)") }
        said += lines.all
        #expect(lines.all.count >= 6, "\(lines.all)")
        let keyLines = (testKey.pemRepresentation + "\n" + testKey.pkcs8PEMRepresentation).split(whereSeparator: \.isNewline)
            .map(String.init).filter { !$0.hasPrefix("-----") }
        let jwts = github.calls.map(\.jwt)
        #expect(!keyLines.isEmpty && !jwts.isEmpty && minted.count == 4)
        for line in said {
            #expect(!line.contains("ghs_"), "\(line)")
            for token in minted { #expect(!line.contains(token)) }
            for jwt in jwts {
                #expect(!line.contains(jwt))
                for part in jwt.split(separator: ".") { #expect(!line.contains(part), "\(line)") }
            }
            for keyLine in keyLines { #expect(!line.contains(keyLine), "\(line)") }
        }
    }

    /// The interceptor as the host makes it: the App before the auth token,
    /// and the App's line said at the start, before any request (its
    /// installation named, so no GitHub is asked); a key that isn't one said
    /// as well.
    @Test func theInterceptorSaysTheAppAtTheStart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-proxy-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pem = testKey.pemRepresentation
        for (key, said) in [(pem, "github: tokens minted as the GitHub App 123456 (installation 42 of AttilaTheFun), hourly, for all of AttilaTheFun's"),
                            ("not a key", "github: the App's key isn't a PEM")] {
            let lines = Lines()
            let interceptor = GitHubInterceptor.make(secrets: MemoryProxySecrets(), caCertificate: folder.appendingPathComponent("ca.pem").path,
                                                     gateRules: nil, token: { "github_pat_x" },
                                                     app: { GitHubAppSecrets(key: key, id: "123456", installation: "42") },
                                                     egress: nil, log: { lines.add($0) })
            defer { interceptor?.stop() }
            #expect(interceptor != nil)
            #expect(lines.all.contains { $0.hasSuffix("with the GitHub App's installation tokens") }, "\(lines.all)")
            for _ in 0..<100 where !lines.all.contains(said) { try await Task.sleep(for: .milliseconds(50)) }
            #expect(lines.all.contains(said), "\(lines.all)")
        }
    }
}
