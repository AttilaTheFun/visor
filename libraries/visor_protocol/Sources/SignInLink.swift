import Foundation

/// A `visor://sign-in?computer=<address>` link: opened, Visor comes to the
/// front on that computer's settings, where it is signed in to.
public struct SignInLink: Equatable, Sendable {
    /// The computer's address, as Visor holds it.
    public var computer: String

    public init(computer: String) { self.computer = computer }

    public var link: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return "\(ConnectionCode.scheme)://sign-in?computer=" + (computer.addingPercentEncoding(withAllowedCharacters: allowed) ?? computer)
    }

    /// A link, or one with whitespace around it; nil for anything else.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("\(ConnectionCode.scheme)://sign-in?"),
              let query = trimmed.split(separator: "?", maxSplits: 1).last else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "computer",
                  let computer = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  !computer.isEmpty else { continue }
            self.init(computer: computer)
            return
        }
        return nil
    }
}
