// The GitHub App's bot, as git names it (0.72.1, from Logan's container
// test: `git commit` in the Sessions container had no identity, "unable to
// auto-detect email address"): `<slug>[bot]`, and GitHub's noreply address
// for the App's bot user, `<id>+<slug>[bot]@users.noreply.github.com`, so
// GitHub shows its commits as the App's. The slug is the App's (`GET
// /app`, with its JWT), the id its bot user's (`GET
// /users/<slug>%5Bbot%5D`, with an installation token). Found by
// GitHubAppTokens once for each generation of the App's secrets; the
// server hands it to the container's agents as git's environment.

import Foundation

/// The App's bot user, as git's author and committer.
public struct GitHubAppIdentity: Equatable, Sendable {
    /// The App's slug, as GitHub gives it (`logan-shire-agent`).
    public let slug: String
    /// Its bot user's id.
    public let userID: Int

    public init(slug: String, userID: Int) {
        self.slug = slug
        self.userID = userID
    }

    /// `<slug>[bot]`: the bot user's login, and git's name.
    public var name: String { "\(slug)[bot]" }
    /// `<id>+<slug>[bot]@users.noreply.github.com`: git's email.
    public var email: String { "\(userID)+\(name)@users.noreply.github.com" }

    /// Whether `text` is a slug as GitHub makes them: letters, digits and
    /// hyphens, nothing else (so it goes in a path and an address as it is).
    static func isSlug(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The bot user's path in GitHub's API, its brackets escaped.
    static func userPath(slug: String) -> String { "/users/\(slug)%5Bbot%5D" }
}
