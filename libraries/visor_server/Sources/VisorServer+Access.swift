// Who is let in: the password, and the tokens `hello` hands out; and
// where the password is kept.

import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

extension VisorServer {
    /// The folder an earlier build kept its cache in (Application Support,
    /// by bundle id), taken over the first time this build runs.
    static func adoptFormerFolders() {
        guard storeRoot == nil, let current = Bundle.main.bundleIdentifier, !formerBundleIDs.contains(current) else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let target = base.appendingPathComponent(current)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        for former in formerBundleIDs {
            let source = base.appendingPathComponent(former)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: target)
                return
            }
        }
    }

    /// The password as kept — the keychain — or, the first time, as an
    /// earlier build kept it (in its settings), moved into the keychain.
    static func keptPassword() -> String {
        if let kept = secrets.get("password"), !kept.isEmpty { return kept }
        let earlier = [UserDefaults.standard] + formerBundleIDs.compactMap { UserDefaults(suiteName: $0) }
        for defaults in earlier {
            if let old = defaults.string(forKey: "visor.password"), !old.isEmpty {
                secrets.set("password", old)
                for place in earlier { place.removeObject(forKey: "visor.password") }
                return old
            }
        }
        return ""
    }

    /// Whether a request may be answered: it came on a trusted connection
    /// (the socket file, through SSH as this user), or the bearer is the
    /// password or a token `hello` issued.
    func authorized(_ request: HTTPRequest) -> Bool {
        if request.trusted || settings.asksNothing { return true }
        guard let bearer = request.authorization, !bearer.isEmpty else { return false }
        // The agent token too: the agents this server started (and the
        // tools they run, such as a deploy) hold it, and no one else.
        return bearer == password || tokens.contains(bearer) || bearer == agentToken
    }

    /// The answer to a request that is not let in: it wants the password.
    func refusal(_ request: HTTPRequest) -> HTTPResponse {
        HTTPResponse(401, "{\"error\":\"wrong password\"}")
    }

    /// A token for the socket's login, for a client that `hello` let in.
    func issueToken() -> String {
        let token = UUID().uuidString.lowercased()
        tokens.append(token)
        if tokens.count > 512 { tokens.removeFirst(tokens.count - 512) }
        return token
    }

    /// Four short words, easy to type on a phone.
    public static func generatePassword() -> String {
        let words = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "heron", "iris", "jade", "kelp", "lumen", "maple", "north", "ocean", "pearl", "quill", "river", "stone", "tidal", "umber", "vale", "wren", "zephyr"]
        return (0..<4).map { _ in words.randomElement()! }.joined(separator: "-")
    }
}
