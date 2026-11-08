import Foundation

/// A way to sign in to the Runner (docs/runner-accounts.md): the Runner's
/// own password by default; OpenID Connect and GitHub later, and the fork's
/// own in their place. Whichever proves who the client is, the Runner then
/// gives it a session of its own (RunnerSessions), so no provider's token
/// goes any further.
public protocol RunnerAuth: Sendable {
    /// Its name in `GET /runner/v1/sign-in`, and the `kind` a sign-in names.
    var kind: String { get }
    /// The user a sign-in's proof (its JSON body) proves, or nil.
    func user(for proof: [String: Any]) -> String?
}
