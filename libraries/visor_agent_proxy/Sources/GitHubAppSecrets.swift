// The GitHub App's secrets, as agent-proxy keeps them now (Logan approved
// the App as a choice for 0.71.1: container agents act as logan-shire-agent,
// never as him): `github-app/key`, its private key (a PEM: PKCS #1, which
// GitHub issues, or PKCS #8); `github-app/id`, its id; and, optional,
// `github-app/installation`, its installation's id (without it, found by the
// gate's owner). The key and the id both set, the gate's token is the App's
// (PreferredGitHubToken). Never logged, never said back: its description
// names the App alone.

import Foundation

/// The App's secrets as kept now.
public struct GitHubAppSecrets: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The App's private key, a PEM.
    public let key: String
    /// The App's id: the JWT's issuer.
    public let id: String
    /// Its installation's id, where it's given.
    public let installation: String?

    /// The App's secrets, or nil unless both its key and its id are set (a
    /// blank one is none).
    public init?(key: String?, id: String?, installation: String? = nil) {
        func given(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        guard let key = given(key), let id = given(id) else { return nil }
        self.key = key
        self.id = id
        self.installation = given(installation)
    }

    /// The App, never its key.
    public var description: String { "the GitHub App \(id)'s secrets" }
    public var debugDescription: String { description }
}
