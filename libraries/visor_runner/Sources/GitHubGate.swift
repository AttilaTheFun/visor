import Foundation

/// The GitHub proxy's policy (docs/github-proxy.md, docs/github-gate-rules.md):
/// what of an agent's request to GitHub goes on, what goes on only after the
/// proxy has read GitHub (GateCheck), and what is refused, in gh_mcp's
/// words. Default deny. It reads the request alone; the proxy makes the
/// reads a check asks for, holds the token, and answers a refusal in the
/// client's own form.
public struct GitHubGate: Sendable {
    public var rules: GateRules

    public init(rules: GateRules = .standard) {
        self.rules = rules
    }

    /// The hosts the proxy opens.
    public static let hosts: Set<String> = ["github.com", "api.github.com", "uploads.github.com"]

    public func decide(_ request: GateRequest) -> GateDecision {
        guard let segments = Self.segments(request.path) else {
            return .refuse("\(request.path) is no plain path: no empty, . or .. segment, and no encoded /, . or \\")
        }
        switch request.host.lowercased() {
        case "api.github.com":
            if request.method == "POST", segments == ["graphql"] { return decideGraphQL(request) }
            return decideREST(request, segments)
        case "github.com":
            return decideGit(request, segments)
        case "uploads.github.com":
            return .refuse("uploads.github.com takes release assets, which agents don't upload")
        default:
            return .refuse("\(request.host) is not GitHub's")
        }
    }

    /// A path's segments, if it is plain: no empty, `.` or `..` segment, and
    /// no percent-encoded `/`, `.` or `\` in one, so that no segment can climb
    /// out of a repository's prefix (`/repos/A/x/../../repos/B/y`).
    static func segments(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments == [""] { return [] }
        for segment in segments {
            if segment.isEmpty || segment == "." || segment == ".." { return nil }
            let lowered = segment.lowercased()
            if lowered.contains("%2f") || lowered.contains("%2e") || lowered.contains("%5c") || lowered.contains("%00") { return nil }
        }
        return segments
    }

    /// `owner/name`, from a path's two segments, if it names an allowed
    /// repository; else why not.
    func repository(_ owner: String, _ name: String) -> Result<String, Refusal> {
        let repository = owner + "/" + name
        guard Self.isOwner(owner), Self.isName(name) else { return .failure(Refusal("\(repository) is not a repository's owner/name")) }
        guard rules.allows(repository) else {
            return .failure(Refusal("\(repository) is not among the repositories Visor's proxy allows (\(rules.named))"))
        }
        return .success(repository)
    }

    /// `owner/name`, from a path's two segments, if it names a repository
    /// that isn't among the allowed ones: what an anonymous read is of. Nil
    /// for an allowed one, or for what names no repository.
    func outside(_ owner: String, _ name: String) -> String? {
        let repository = owner + "/" + name
        guard Self.isOwner(owner), Self.isName(name), !rules.allows(repository) else { return nil }
        return repository
    }

    struct Refusal: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// GitHub's owners: 1-39 letters, digits and `-` ([R1]).
    static func isOwner(_ text: String) -> Bool {
        (1...39).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// GitHub's repository names: 1-100 letters, digits, `.`, `_` and `-`,
    /// not `.` or `..` ([R1]).
    static func isName(_ text: String) -> Bool {
        (1...100).contains(text.count) && text != "." && text != ".."
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }
}
