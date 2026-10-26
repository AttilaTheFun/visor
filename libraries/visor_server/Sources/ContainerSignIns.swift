import Foundation

/// The agents' sign-ins for containers, kept by this server apart from this
/// computer's own (which a Linux container cannot use: Claude Code's is in
/// the Mac's keychain), and never in the image:
///
///     <data>/containers/agent.env   CLAUDE_CODE_OAUTH_TOKEN=… (`claude setup-token`)
///     <data>/containers/codex/      Codex's home in every container (its
///                                   sessions folder the computer's): a sign-in of
///                                   its own, made once in a container
///                                   (`codex login --device-auth`), never a copy
///                                   of the computer's: Codex rotates its refresh
///                                   token, and the first of two copies to
///                                   refresh signs the other out
///     <data>/containers/openrouter/ openrouter's home in every container (its
///                                   sessions folder the computer's): its key and
///                                   default model, set once in a container
///                                   (`openrouter auth login`), or the key as
///                                   OPENROUTER_API_KEY in agent.env
///     <data>/containers/home/       other files copied into each container's
///                                   home when it is made
enum ContainerSignIns {
    /// Where they are kept.
    static var folder: URL { ServerPlatform.current.host.dataDirectory.appendingPathComponent("containers", isDirectory: true) }

    /// Codex's home in every container, made (this user's alone) when asked
    /// for.
    static var codexHome: URL {
        let home = folder.appendingPathComponent("codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return home
    }

    /// openrouter's home in every container, made (this user's alone) when
    /// asked for.
    static var openrouterHome: URL {
        let home = folder.appendingPathComponent("openrouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return home
    }

    /// The variables every agent in a container starts with.
    static func environment() -> [String: String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("agent.env", isDirectory: false), encoding: .utf8) else { return [:] }
        var variables: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            variables[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return variables
    }

    /// The files copied into a container's home: each by its path there.
    static func homeFiles() -> [(path: String, data: Data)] {
        let home = folder.appendingPathComponent("home", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [(String, Data)] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = String(url.standardizedFileURL.path.dropFirst(home.standardizedFileURL.path.count + 1))
            if let data = try? Data(contentsOf: url) { files.append((path, data)) }
        }
        return files.sorted { $0.0 < $1.0 }
    }
}
