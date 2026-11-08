import Crypto
import Foundation
import Synchronization

/// The sessions of the clients signed in to this Runner (docs/runner-accounts.md):
/// whoever proved who they are, by whichever sign-in, is given a token of
/// the Runner's own, the client's one bearer from then on. The secrets keep
/// each session by its token's SHA-256 (never the token), with its user and
/// when it ends, so a launch keeps them and a stolen secrets file signs no
/// one in. Ended by signing out, or when its time is up.
public final class RunnerSessions: Sendable {
    /// Where the secrets keep them: JSON of `[sha256(token): Session]`.
    public static let secret = "runner sessions"
    /// How long a session lasts.
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    struct Session: Codable, Equatable {
        var user: String
        /// When it ends, in seconds since 1970.
        var expires: Double
    }

    private let secrets: RunnerSecrets
    /// Read and written under this, so two sign-ins at once lose neither.
    private let lock = Mutex(())

    public init(secrets: RunnerSecrets) {
        self.secrets = secrets
    }

    /// A new session for `user`: its token, and when it ends.
    public func begin(user: String, now: Date = Date()) -> (token: String, expires: Date) {
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let expires = now.addingTimeInterval(Self.lifetime)
        lock.withLock { _ in
            var kept = live(now: now)
            kept[Self.key(token)] = Session(user: user, expires: expires.timeIntervalSince1970)
            keep(kept)
        }
        return (token, expires)
    }

    /// The user a token is a live session of, or nil.
    public func user(for token: String, now: Date = Date()) -> String? {
        guard !token.isEmpty else { return nil }
        return lock.withLock { _ in live(now: now)[Self.key(token)]?.user }
    }

    /// Ends the session a token is, if it is one.
    public func end(_ token: String, now: Date = Date()) {
        lock.withLock { _ in
            var kept = live(now: now)
            kept[Self.key(token)] = nil
            keep(kept)
        }
    }

    /// Ends every session of a user (its password changed, or it was removed).
    public func endAll(of user: String, now: Date = Date()) {
        lock.withLock { _ in keep(live(now: now).filter { $0.value.user != user }) }
    }

    /// The sessions not yet over.
    private func live(now: Date) -> [String: Session] {
        guard let text = secrets.value(Self.secret), let all = try? JSONDecoder().decode([String: Session].self, from: Data(text.utf8))
        else { return [:] }
        return all.filter { $0.value.expires > now.timeIntervalSince1970 }
    }

    private func keep(_ sessions: [String: Session]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        secrets.set(Self.secret, sessions.isEmpty ? nil : String(decoding: data, as: UTF8.self))
    }

    static func key(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
