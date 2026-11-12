// The GitHub proxy's one token (docs/github-proxy.md; Logan, 7 Nov 2026): the
// agents' App's installation token, minted by the Runner with the App's key
// (a JWT, RS256), kept in memory until shortly before it expires, and asked
// for again once GitHub turns it down. No agent, server or container holds
// the key or the token.

import _CryptoExtras
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
@testable import VisorRunner
import Testing

/// GitHub's token endpoint, played: what it was asked, and a token.
private final class TokenEndpoint: Sendable {
    let asked = Mutex<[URLRequest]>([])
    let status: Int

    init(status: Int = 201) { self.status = status }

    var fetch: GitHubAppTokens.Fetch {
        { [self] request in
            let count = asked.withLock { asked in
                asked.append(request)
                return asked.count
            }
            let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            return (Data("{\"token\":\"ghs_minted\(count)\",\"expires_at\":\"\(expires)\"}".utf8), status)
        }
    }
}

@Suite final class GitHubAppTokensTests {
    private let key = try! _RSA.Signing.PrivateKey(keySize: .bits2048)

    @Test func testTheJWTIsTheAppsSignedWithItsKey() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = try GitHubAppTokens.jwt(appID: "123", pem: key.pemRepresentation, now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decoded(_ text: String) -> Data? {
            var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            return Data(base64Encoded: base64)
        }
        let claims = try #require(try JSONSerialization.jsonObject(with: try #require(decoded(parts[1]))) as? [String: Any])
        #expect((claims["iss"] as? String) == "123")
        #expect((claims["iat"] as? Int) == (1_800_000_000 - 60))
        #expect((claims["exp"] as? Int) == (1_800_000_000 + 540), "nine minutes: GitHub takes at most ten")
        let signature = _RSA.Signing.RSASignature(rawRepresentation: try #require(decoded(parts[2])))
        #expect(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8), padding: .insecurePKCS1v1_5))
    }

    @Test func testOneTokenIsMintedKeptAndAskedForAgainWhenTurnedDown() async throws {
        let endpoint = TokenEndpoint()
        let pem = key.pemRepresentation
        let tokens = GitHubAppTokens(appID: "123", installation: "456", key: { pem }, fetch: endpoint.fetch)
        let first = try await tokens.token(session: "a", repository: "AttilaTheFun/visor")
        let second = try await tokens.token(session: "b", repository: "AttilaTheFun/shireworks")
        #expect([first, second] == ["ghs_minted1", "ghs_minted1"], "one token for every session and repository")
        let asked = try #require(endpoint.asked.withLock { $0.first })
        #expect(asked.httpMethod == "POST")
        #expect((asked.url?.absoluteString) == "https://api.github.com/app/installations/456/access_tokens")
        #expect(asked.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ey") == true, "the App's JWT")
        await tokens.forget(session: "a", repository: "AttilaTheFun/visor")
        let third = try await tokens.token(session: "a", repository: "AttilaTheFun/visor")
        #expect(third == "ghs_minted2", "asked again once turned down")
    }

    @Test func testNoKeyOrAnAnswerWithoutATokenIsAFailure() async throws {
        let none = GitHubAppTokens(appID: "123", installation: "456", key: { nil }, fetch: TokenEndpoint().fetch)
        do {
            _ = try await none.token(session: "a", repository: "r")
            Issue.record("a token without a key")
        } catch {
            #expect("\(error)".contains("no App key"), "\(error)")
        }
        let pem = key.pemRepresentation
        let refused = GitHubAppTokens(appID: "123", installation: "456", key: { pem }, fetch: TokenEndpoint(status: 401).fetch)
        do {
            _ = try await refused.token(session: "a", repository: "r")
            Issue.record("a token GitHub didn't give")
        } catch {
            #expect("\(error)".contains("401"), "\(error)")
        }
    }
}
