import Foundation

/// A GitHub repository, `owner/name`.
public struct RepoName: Sendable, Hashable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init?(owner: String, name: String) {
        guard Self.isOwner(owner), Self.isName(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    /// From `Owner/name`.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    /// From a remote's URL, if it is GitHub's: https://github.com/O/N(.git),
    /// git@github.com:O/N(.git), ssh://git@github.com(:22)/O/N(.git).
    public init?(remoteURL: String) {
        var rest: Substring
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = url.range(of: "://") {
            guard ["https", "http", "ssh", "git"].contains(url[..<scheme.lowerBound].lowercased()) else { return nil }
            rest = url[scheme.upperBound...]
            if let at = rest.firstIndex(of: "@"), at < (rest.firstIndex(of: "/") ?? rest.endIndex) {
                rest = rest[rest.index(after: at)...]
            }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let host = rest[..<slash].split(separator: ":").first.map(String.init) ?? ""
            guard host.lowercased() == "github.com" else { return nil }
            rest = rest[rest.index(after: slash)...]
        } else {
            // scp-like: [user@]github.com:Owner/name
            guard let colon = url.firstIndex(of: ":") else { return nil }
            var host = url[..<colon]
            if let at = host.firstIndex(of: "@") { host = host[host.index(after: at)...] }
            guard host.lowercased() == "github.com" else { return nil }
            rest = url[url.index(after: colon)...]
        }
        var path = String(rest)
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        self.init(path)
    }

    public var description: String { "\(owner)/\(name)" }

    static func isOwner(_ text: String) -> Bool {
        (1...39).contains(text.count) && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    static func isName(_ text: String) -> Bool {
        (1...100).contains(text.count) && text != "." && text != ".."
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }
}
