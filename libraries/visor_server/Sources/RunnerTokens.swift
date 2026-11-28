// The runners' own tokens: what a runner shows on agent_protocol's Claim
// (`authorization: Bearer <runner token>`), each minted for one runner
// name (`container@<computer>`) and good only for claims made under that
// name. Minted, listed and revoked over REST by the computer's owner
// (`/api/runners/tokens`; VisorServer+RunnerTokens), never by an agent.
// Kept with the server's secrets (`runnerTokens`: name to token and when
// it was minted), never in the sessions' store, jobs.json or the log; shown once,
// when minted. This server's own runner (Visor's native runner, in this
// process, on loopback) is given one at its start, held in memory alone.
//
// Whether a claim must show one is the server's `runnerTokensRequired`
// setting, off until the runners that claim here send one: off, a claim
// with none is let in (and logged, once per runner); a token that isn't a
// runner's, or is another runner's, is refused either way.

import Foundation

@MainActor
package final class RunnerTokens {
    /// A runner's token as kept: the token, and when it was minted (ISO
    /// 8601).
    package struct Kept: Codable, Equatable, Sendable {
        package var token: String
        package var created: String
    }

    /// A runner as listed: its name, when its token was minted, and
    /// whether it is this server's own runner's (held in memory alone).
    package struct Listed: Equatable, Sendable {
        package let runner: String
        package let created: String
        package let own: Bool
    }

    /// Whether a call is let in, and if not, why (a gRPC status's).
    package enum Admission: Equatable, Sendable {
        case admitted
        /// No runner token where one is required, or one this server
        /// didn't mint (or revoked).
        case unauthenticated(String)
        /// A runner token, but another runner's.
        case permissionDenied(String)
    }

    /// Where they are kept among the server's secrets.
    package static let key = "runnerTokens"

    private let secrets: any SecretStore
    private var kept: [String: Kept]
    /// This server's own runners' tokens, by name: minted at each start.
    private var own: [String: Kept] = [:]
    /// The runners whose claims without a token were let in and logged.
    private var warned: Set<String> = []

    package init(secrets: any SecretStore) {
        self.secrets = secrets
        if let text = secrets.get(Self.key), let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Kept].self, from: data) {
            kept = decoded
        } else {
            kept = [:]
        }
    }

    /// Why `runner` can't be a runner token's name, if it can't: it is
    /// what a runner says in its claims, and a path's last part.
    package static func problem(withName runner: String) -> String? {
        if runner.isEmpty { return "A runner token is for a runner: send {\"runner\": \"<its name, as its claims say>\"}." }
        if runner != runner.trimmingCharacters(in: .whitespaces) { return "A runner's name doesn't start or end with a space." }
        if runner.count > 200 { return "A runner's name is at most 200 characters." }
        if runner.contains("/") || runner.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "A runner's name has no slash or control characters."
        }
        return nil
    }

    /// A new token for `runner`, kept: the token (shown this once), when it
    /// was minted, and whether it replaced one (which no longer works).
    package func mint(for runner: String) -> (token: String, created: String, replaced: Bool) {
        let made = Kept(token: Self.newToken(), created: Self.now())
        let replaced = kept.updateValue(made, forKey: runner) != nil
        keep()
        VisorServer.log("runner tokens: \(replaced ? "a new token for" : "minted for") \(runner)")
        return (made.token, made.created, replaced)
    }

    /// A token for this server's own runner (in this process), held in
    /// memory alone: a new one each start.
    package func issueOwn(for runner: String) -> String {
        let made = Kept(token: Self.newToken(), created: Self.now())
        own[runner] = made
        return made.token
    }

    /// `runner`'s token gone, kept or own: whether it had one.
    package func revoke(_ runner: String) -> Bool {
        let had = kept.removeValue(forKey: runner) != nil
        let hadOwn = own.removeValue(forKey: runner) != nil
        if had { keep() }
        if had || hadOwn { VisorServer.log("runner tokens: \(runner)'s revoked") }
        return had || hadOwn
    }

    /// The runners with a token, by name: never the tokens.
    package var listed: [Listed] {
        let mine = own.map { Listed(runner: $0.key, created: $0.value.created, own: true) }
        let theirs = kept.map { Listed(runner: $0.key, created: $0.value.created, own: false) }
        return (mine + theirs).sorted { ($0.runner, $0.own ? 0 : 1) < ($1.runner, $1.own ? 0 : 1) }
    }

    /// The runner whose token `token` is, if any.
    package func runner(presenting token: String) -> String? {
        guard !token.isEmpty else { return nil }
        for (runner, held) in own where SecretToken.same(token, held.token) { return runner }
        for (runner, held) in kept where SecretToken.same(token, held.token) { return runner }
        return nil
    }

    /// Whether a claim made as `runner`, showing `bearers`, is let in.
    /// None shown: only while tokens aren't `required` (logged once per
    /// runner). Shown: one must be `runner`'s own, required or not.
    package func admit(claimBy runner: String, bearers: [String], required: Bool) -> Admission {
        let shown = bearers.filter { !$0.isEmpty }
        guard !shown.isEmpty else {
            if required {
                return .unauthenticated("A claim shows its runner's token (authorization: Bearer <runner token>): this server requires one.")
            }
            if warned.insert(runner).inserted {
                VisorServer.log("dispatcher: \(runner) claims without a runner token: let in while runner tokens aren't required (runnerTokensRequired)")
            }
            return .admitted
        }
        let names = shown.compactMap { self.runner(presenting: $0) }
        guard let first = names.first else { return .unauthenticated("That isn't a runner token of this server's (or it was revoked).") }
        guard names.contains(runner) else { return .permissionDenied("That runner token is \(first)'s, not \(runner)'s.") }
        return .admitted
    }

    /// Whether a call for an agent whose claim `runner` holds (its renewal,
    /// its release), showing `bearers`, may go on: any runner token among
    /// them must be that runner's. The agent's own token is asked apart.
    package func admit(callFor runner: String?, bearers: [String]) -> Admission {
        guard let runner else { return .admitted }
        for bearer in bearers {
            if let name = self.runner(presenting: bearer), name != runner {
                return .permissionDenied("That runner token is \(name)'s; the claim is \(runner)'s.")
            }
        }
        return .admitted
    }

    private func keep() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(kept) else { return }
        secrets.set(Self.key, kept.isEmpty ? nil : String(decoding: data, as: UTF8.self))
    }

    /// 32 random bytes, as hex (SecretToken).
    private static func newToken() -> String {
        SecretToken.mint()
    }

    private static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
