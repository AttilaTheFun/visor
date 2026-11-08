import Foundation

/// The Runner's one user and its password (`visor-runner-agent user set`):
/// the default sign-in. The proof is `{"username", "password"}`; the name is
/// runner.json's `user`, the password checked against its scrypt hash in
/// the Runner's secrets.
public struct RunnerPasswordAuth: RunnerAuth {
    /// Where the secrets keep the password's hash.
    public static let secret = "runner user password"

    public let kind = "password"
    private let user: @Sendable () -> String?
    private let secrets: RunnerSecrets

    /// `user`: the Runner's user as runner.json says it now.
    public init(user: @escaping @Sendable () -> String?, secrets: RunnerSecrets) {
        self.user = user
        self.secrets = secrets
    }

    public func user(for proof: [String: Any]) -> String? {
        guard let name = user(), !name.isEmpty, let hash = secrets.value(Self.secret),
              let given = proof["username"] as? String, given == name, let password = proof["password"] as? String,
              RunnerPassword.verifies(password, against: hash) else { return nil }
        return name
    }
}
