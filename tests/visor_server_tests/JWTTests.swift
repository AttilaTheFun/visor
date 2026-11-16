// The agents' tokens as JWTs (compact JWS, HS256): signed and verified with
// the signing keys alone; refused for the wrong key, kid, issuer, audience,
// agent or scope, past their end, or with another algorithm in their
// header. A rotation keeps the key before (and its tokens) for a day, then
// drops it; an emergency rotation drops it at once.

import Foundation
@testable import VisorServer
import Testing

extension ServerTests {
@Suite @MainActor struct JWTTests {
    private let secrets = MemorySecrets()

    @Test func aTokenIsSignedAndVerified() throws {
        let tokens = AgentTokens(secrets: secrets, issuer: "server-1")
        let token = tokens.mint(.runnerAgent, session: "S", agent: "Agent-1")
        let parts = try #require(JWT.parts(of: token))
        #expect(parts.header == JWT.Header(alg: "HS256", typ: "JWT", kid: tokens.keys.currentKID))
        let claims = try tokens.verify(token, as: .runnerAgent, agent: "agent-1", scope: .job).get()
        #expect(claims.iss == "server-1" && claims.aud == "visor.runner-agent" && claims.sub == "S" && claims.agent == "agent-1")
        #expect(claims.scope == ["messages", "approvals", "mcp", "job"] && claims.exp - claims.iat == 3600)
        #expect(tokens.verify(token, as: .runnerAgent, agent: "AGENT-1").isSuccess, "however the agent is spelt")
        #expect(tokens.mint(.runnerAgent, session: "S", agent: "agent-1") != token, "each its own jti")
        // The payload is the claims, base64url without padding.
        #expect(!token.contains("=") && !token.contains("+") && !token.contains("/"))
        let payload = try JSONDecoder().decode(AgentTokenClaims.self, from: parts.payload)
        #expect(payload == claims)
    }

    @Test func aWrongTokenIsRefused() throws {
        let tokens = AgentTokens(secrets: secrets, issuer: "server-1")
        let token = tokens.mint(.runnerAgent, session: "S", agent: "agent-1")
        let claims = try tokens.verify(token, as: .runnerAgent, agent: "agent-1").get()
        let (kid, key) = tokens.keys.current
        // The wrong key, under its kid; a kid not held.
        #expect(tokens.verify(try JWT.sign(claims, key: Data(repeating: 1, count: 32), kid: kid), as: .runnerAgent, agent: "agent-1")
                == .failure(.badSignature))
        #expect(tokens.verify(try JWT.sign(claims, key: key, kid: "feedfacefeedface"), as: .runnerAgent, agent: "agent-1")
                == .failure(.unknownKey))
        // Another issuer, with the same key.
        var other = claims
        other.iss = "server-2"
        #expect(tokens.verify(try JWT.sign(other, key: key, kid: kid), as: .runnerAgent, agent: "agent-1") == .failure(.wrongIssuer))
        // Another audience; another agent; a scope it hasn't.
        #expect(tokens.verify(token, as: .session) == .failure(.wrongAudience))
        #expect(tokens.verify(token, as: .runnerAgent, agent: "agent-2") == .failure(.wrongAgent))
        #expect(tokens.verify(token, as: .runnerAgent) == .failure(.wrongAgent), "a runner's agent's names its agent")
        var narrow = claims
        narrow.scope = ["messages"]
        #expect(tokens.verify(try JWT.sign(narrow, key: key, kid: kid), as: .runnerAgent, agent: "agent-1", scope: .job)
                == .failure(.outOfScope))
        // A session's token naming an agent isn't a session's.
        var named = try tokens.verify(tokens.mint(.session, session: "S"), as: .session).get()
        named.agent = "agent-1"
        #expect(tokens.verify(try JWT.sign(named, key: key, kid: kid), as: .session) == .failure(.wrongAudience))
        // Past its end; taken only when the caller allows it.
        let expired = tokens.mint(.runnerAgent, session: "S", agent: "agent-1", now: Date().addingTimeInterval(-3601))
        #expect(tokens.verify(expired, as: .runnerAgent, agent: "agent-1") == .failure(.expired))
        #expect(tokens.verify(expired, as: .runnerAgent, agent: "agent-1", allowExpired: true).isSuccess)
        // Another algorithm in the header: refused before any key.
        let pieces = token.split(separator: ".").map(String.init)
        for alg in ["none", "HS512", "RS256"] {
            let header = JWT.base64URL(Data(#"{"alg":"\#(alg)","kid":"\#(kid)","typ":"JWT"}"#.utf8))
            #expect(tokens.verify(header + "." + pieces[1] + "." + pieces[2], as: .runnerAgent, agent: "agent-1") == .failure(.malformed))
            #expect(tokens.verify(header + "." + pieces[1] + ".", as: .runnerAgent, agent: "agent-1") == .failure(.malformed))
        }
        for shape in ["", "a.b", "a.b.c.d", pieces[0] + "." + pieces[1], "!!.??.**"] {
            #expect(tokens.verify(shape, as: .runnerAgent, agent: "agent-1") == .failure(.malformed), Comment(rawValue: shape))
        }
    }

    @Test func aRotationKeepsTheKeyBeforeForADayThenDropsIt() throws {
        let start = Date()
        let tokens = AgentTokens(secrets: secrets, issuer: "server-1")
        let old = tokens.mint(.session, session: "S", now: start)
        let oldKID = tokens.keys.currentKID
        let newKID = tokens.keys.rotate(dropPrevious: false, now: start)
        #expect(newKID != oldKID && tokens.keys.currentKID == newKID)
        let new = tokens.mint(.session, session: "S", now: start)
        #expect(JWT.parts(of: new)?.header.kid == newKID)
        #expect(tokens.verify(old, as: .session, now: start.addingTimeInterval(3600)).isSuccess, "the key before still held")
        // Kept with the secrets: another launch holds the same.
        let relaunched = AgentTokens(secrets: secrets, issuer: "server-1")
        #expect(relaunched.verify(old, as: .session).isSuccess && relaunched.verify(new, as: .session).isSuccess)
        // A day on, the key before is gone (and its tokens had ended).
        let dayOn = start.addingTimeInterval(24 * 3600 + 1)
        #expect(tokens.keys.key(oldKID, now: dayOn) == nil)
        #expect(tokens.verify(old, as: .session, now: dayOn, allowExpired: true) == .failure(.unknownKey))
        tokens.keys.prune(now: dayOn)
        #expect(tokens.keys.kids == [newKID])
        #expect(tokens.verify(new, as: .session, now: start.addingTimeInterval(3600)).isSuccess)
    }

    @Test func anEmergencyRotationRefusesEveryTokenBefore() {
        let tokens = AgentTokens(secrets: secrets, issuer: "server-1")
        let session = tokens.mint(.session, session: "S")
        let runner = tokens.mint(.runnerAgent, session: "S", agent: "agent-1")
        tokens.keys.rotate(dropPrevious: false)
        tokens.keys.rotate(dropPrevious: true)
        #expect(tokens.keys.kids == [tokens.keys.currentKID])
        #expect(tokens.verify(session, as: .session) == .failure(.unknownKey))
        #expect(tokens.verify(runner, as: .runnerAgent, agent: "agent-1", allowExpired: true) == .failure(.unknownKey))
        #expect(tokens.verify(tokens.mint(.session, session: "S"), as: .session).isSuccess)
        #expect(AgentTokens(secrets: secrets, issuer: "server-1").verify(session, as: .session) == .failure(.unknownKey),
                "dropped from the secrets too")
    }

    @Test func theKeysAreRandomThirtyTwoBytes() throws {
        let first = SigningKeys(secrets: MemorySecrets())
        let second = SigningKeys(secrets: MemorySecrets())
        #expect(first.current.key.count == 32 && second.current.key.count == 32)
        #expect(first.current.key != second.current.key && first.currentKID != second.currentKID)
    }
}
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
