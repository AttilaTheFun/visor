// The agents' tokens as JWTs (compact JWS, HS256): signed and verified with
// the signing keys alone; refused for the wrong key, kid, issuer, audience,
// agent or scope, past their end, or with another algorithm in their
// header. A rotation keeps the key before (and its tokens) for a day, then
// for a day more only for what may be taken past its end (a runner's Renew
// and Release, `withinGrace`), then drops it; an emergency rotation drops
// it at once. A token past its end is taken only within its grace, and
// only when asked. Kept keys that can't be read are never written over.

import Foundation
import Synchronization
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
        let (kid, key) = try #require(tokens.keys.current)
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
        // Past its end; taken only when the caller allows it, within its
        // grace.
        let expired = tokens.mint(.runnerAgent, session: "S", agent: "agent-1", now: Date().addingTimeInterval(-3601))
        #expect(tokens.verify(expired, as: .runnerAgent, agent: "agent-1") == .failure(.expired))
        #expect(tokens.verify(expired, as: .runnerAgent, agent: "agent-1", withinGrace: true).isSuccess)
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
        let newKID = try #require(tokens.keys.rotate(dropPrevious: false, now: start))
        #expect(newKID != oldKID && tokens.keys.currentKID == newKID)
        let new = tokens.mint(.session, session: "S", now: start)
        #expect(JWT.parts(of: new)?.header.kid == newKID)
        #expect(tokens.verify(old, as: .session, now: start.addingTimeInterval(3600)).isSuccess, "the key before still held")
        // Kept with the secrets: another launch holds the same.
        let relaunched = AgentTokens(secrets: secrets, issuer: "server-1")
        #expect(relaunched.verify(old, as: .session).isSuccess && relaunched.verify(new, as: .session).isSuccess)
        // A day on, the key before is past its life (and its tokens had
        // ended): only what may be taken within its grace is verified.
        let dayOn = start.addingTimeInterval(24 * 3600 + 1)
        #expect(tokens.keys.key(oldKID, now: dayOn) == nil)
        #expect(tokens.keys.key(oldKID, now: dayOn, withinGrace: true) != nil)
        #expect(tokens.verify(old, as: .session, now: dayOn) == .failure(.unknownKey))
        tokens.keys.prune(now: dayOn)
        #expect(tokens.keys.kids(now: dayOn) == [newKID] && tokens.keys.graceKIDs(now: dayOn) == [oldKID], "kept a day more, verify-only")
        // Its grace over too, it is gone.
        let twoDaysOn = start.addingTimeInterval(48 * 3600 + 1)
        #expect(tokens.keys.key(oldKID, now: twoDaysOn, withinGrace: true) == nil)
        #expect(tokens.verify(old, as: .session, now: twoDaysOn, withinGrace: true) == .failure(.unknownKey))
        tokens.keys.prune(now: twoDaysOn)
        #expect(tokens.keys.kids(now: twoDaysOn) == [newKID] && tokens.keys.graceKIDs(now: twoDaysOn).isEmpty)
        #expect(tokens.verify(new, as: .session, now: start.addingTimeInterval(3600)).isSuccess)
    }

    /// An expired runner's agent's token: taken, asked to, for
    /// AgentTokens.expiredTokenGrace past its end and no longer.
    @Test func anEndedTokenIsTakenOnlyWithinItsGrace() {
        let tokens = AgentTokens(secrets: secrets, issuer: "server-1")
        let now = Date()
        let grace = AgentTokens.expiredTokenGrace
        let ended = tokens.mint(.runnerAgent, session: "S", agent: "agent-1", now: now.addingTimeInterval(-3600 - 60))
        #expect(tokens.verify(ended, as: .runnerAgent, agent: "agent-1", now: now) == .failure(.expired), "not unless asked")
        #expect(tokens.verify(ended, as: .runnerAgent, agent: "agent-1", now: now, withinGrace: true).isSuccess)
        let nearly = tokens.mint(.runnerAgent, session: "S", agent: "agent-1", now: now.addingTimeInterval(-3600 - grace + 60))
        #expect(tokens.verify(nearly, as: .runnerAgent, agent: "agent-1", now: now, withinGrace: true).isSuccess, "just within")
        let past = tokens.mint(.runnerAgent, session: "S", agent: "agent-1", now: now.addingTimeInterval(-3600 - grace - 60))
        #expect(tokens.verify(past, as: .runnerAgent, agent: "agent-1", now: now, withinGrace: true) == .failure(.expired), "past it")
        // Its grace doesn't make it anyone else's.
        #expect(tokens.verify(ended, as: .runnerAgent, agent: "agent-2", now: now, withinGrace: true) == .failure(.wrongAgent))
    }

    /// A runner's agent's token signed by the key before an ordinary
    /// rotation, that key a day on (past its life): taken within the
    /// token's grace as an expired one is, and only then.
    @Test func anOrdinaryRotationsDroppedKeyIsTakenWithinTheGrace() throws {
        let start = Date()
        let tokens = AgentTokens(secrets: secrets, issuer: "server-1")
        let runner = tokens.mint(.runnerAgent, session: "S", agent: "agent-1", now: start)
        try #require(tokens.keys.rotate(dropPrevious: false, now: start) != nil)
        let dayOn = start.addingTimeInterval(24 * 3600 + 600)
        tokens.keys.prune(now: dayOn)
        #expect(tokens.verify(runner, as: .runnerAgent, agent: "agent-1", now: dayOn) == .failure(.unknownKey))
        #expect(tokens.verify(runner, as: .runnerAgent, agent: "agent-1", now: dayOn, withinGrace: true).isSuccess,
                "its key past its life, the token within its grace")
        let pastGrace = start.addingTimeInterval(3600 + AgentTokens.expiredTokenGrace + 1)
        #expect(tokens.verify(runner, as: .runnerAgent, agent: "agent-1", now: pastGrace, withinGrace: true) == .failure(.expired))
        // A live token signed by a key past its life is taken only within
        // grace too: the key verifies nothing else.
        var claims = try tokens.verify(runner, as: .runnerAgent, agent: "agent-1", now: start).get()
        claims.exp = Int(dayOn.timeIntervalSince1970) + 3600
        let key = try #require(tokens.keys.key(JWT.parts(of: runner)?.header.kid ?? "", now: dayOn, withinGrace: true))
        let forged = try JWT.sign(claims, key: key, kid: JWT.parts(of: runner)?.header.kid ?? "")
        #expect(tokens.verify(forged, as: .runnerAgent, agent: "agent-1", now: dayOn) == .failure(.unknownKey))
    }

    @Test func anEmergencyRotationRefusesEveryTokenBefore() {
        let tokens = AgentTokens(secrets: secrets, issuer: "server-1")
        let session = tokens.mint(.session, session: "S")
        let runner = tokens.mint(.runnerAgent, session: "S", agent: "agent-1")
        tokens.keys.rotate(dropPrevious: false)
        tokens.keys.rotate(dropPrevious: true)
        #expect(tokens.keys.kids == [tokens.keys.currentKID])
        #expect(tokens.verify(session, as: .session) == .failure(.unknownKey))
        #expect(tokens.verify(runner, as: .runnerAgent, agent: "agent-1", withinGrace: true) == .failure(.unknownKey),
                "not even within its grace")
        #expect(tokens.verify(tokens.mint(.session, session: "S"), as: .session).isSuccess)
        #expect(AgentTokens(secrets: secrets, issuer: "server-1").verify(session, as: .session) == .failure(.unknownKey),
                "dropped from the secrets too")
    }

    @Test func theKeysAreRandomThirtyTwoBytes() throws {
        let first = try #require(SigningKeys(secrets: MemorySecrets()).current)
        let second = try #require(SigningKeys(secrets: MemorySecrets()).current)
        #expect(first.key.count == 32 && second.key.count == 32)
        #expect(first.key != second.key && first.kid != second.kid)
    }

    /// Kept keys that can't be read, or can't be decoded, are left as they
    /// are: nothing is minted, nothing written over, until they read again
    /// (or an emergency rotation replaces them). Keys are made only when
    /// there are none.
    @Test func keysThatCantBeReadAreNeverWrittenOver() throws {
        let store = FlakySecrets()
        let kept = SigningKeys(secrets: store)
        let stored = try #require(store.get(SigningKeys.secretKey), "none kept: made")
        let kid = kept.currentKID

        store.failing = true
        let start = Date()
        let unread = AgentTokens(secrets: store, issuer: "server-1")
        #expect(unread.keys.current == nil && unread.keys.problem != nil)
        #expect(unread.mint(.session, session: "S").isEmpty, "nothing minted")
        #expect(unread.keys.rotate(dropPrevious: false) == nil, "an ordinary rotation refused")
        #expect(store.writes == 1 && store.get(SigningKeys.secretKey, evenIfFailing: true) == stored, "never written over")

        // Read again once they can be.
        store.failing = false
        #expect(unread.keys.key(kid, now: start.addingTimeInterval(SigningKeys.retryInterval + 1)) != nil)
        #expect(unread.keys.currentKID == kid && !unread.mint(.session, session: "S").isEmpty)

        // Kept but undecodable: the same.
        store.set(SigningKeys.secretKey, "not json")
        let writes = store.writes
        let garbled = SigningKeys(secrets: store)
        #expect(garbled.current == nil && garbled.problem != nil)
        #expect(store.writes == writes && store.get(SigningKeys.secretKey) == "not json")
        // An emergency rotation replaces them.
        let fresh = try #require(garbled.rotate(dropPrevious: true))
        #expect(garbled.currentKID == fresh && garbled.problem == nil && store.get(SigningKeys.secretKey) != "not json")
    }
}
}

/// Secrets that fail to be read while `failing`, as a locked keychain does.
private final class FlakySecrets: SecretStore {
    private let state = Mutex<(failing: Bool, writes: Int)>((false, 0))
    private let memory = MemorySecrets()

    var failing: Bool {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }

    var writes: Int { state.withLock { $0.writes } }

    func get(_ key: String) -> String? { failing ? nil : memory.get(key) }
    func get(_ key: String, evenIfFailing: Bool) -> String? { memory.get(key) }

    func set(_ key: String, _ value: String?) {
        state.withLock { $0.writes += 1 }
        memory.set(key, value)
    }

    func lookup(_ key: String) -> SecretLookup {
        failing ? .unreadable("the test's store is failing") : memory.lookup(key)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
