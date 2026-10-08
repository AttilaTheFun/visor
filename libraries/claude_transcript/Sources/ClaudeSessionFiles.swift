// Where Claude Code keeps a session: <its config folder>/projects/<the
// folder's path with "/", "." and "_" as "-">/<session id>.jsonl — the
// config folder ~/.claude, or $CLAUDE_CONFIG_DIR when it is set. The folder is fixed
// when the session starts and kept through renames, so a session whose
// folder moved is looked for everywhere before it is given up on.

import Foundation
import Synchronization

public enum ClaudeSessionFiles {
    /// Whose home the sessions are under: the user's, unless a test says.
    public static var home: URL {
        get { homeDirectory.withLock { $0 } }
        set { homeDirectory.withLock { $0 = newValue } }
    }
    private static let homeDirectory = Mutex(FileManager.default.homeDirectoryForCurrentUser)

    public static func projectsRoot(home: URL = ClaudeSessionFiles.home) -> URL {
        configDirectory(home: home).appendingPathComponent("projects")
    }

    /// Claude Code's own folder: $CLAUDE_CONFIG_DIR when it is set (as
    /// Claude Code reads it, and the agents this server starts inherit
    /// it), else ~/.claude under `home`.
    public static func configDirectory(home: URL = ClaudeSessionFiles.home,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let set = environment["CLAUDE_CONFIG_DIR"], !set.isEmpty {
            return URL(fileURLWithPath: (set as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The project directory's name for a folder.
    public static func projectDirectoryName(for cwd: String) -> String {
        // The folder as Claude Code sees it: the real path, then every
        // "/", "." and "_" as "-".
        var name = realPath((cwd as NSString).expandingTildeInPath)
        for character in ["/", ".", "_"] { name = name.replacingOccurrences(of: character, with: "-") }
        return name
    }

    /// An absolute path with every symbolic link in it followed, as
    /// realpath(3) gives it — not Foundation's resolvingSymlinksInPath,
    /// which strips "/private" on a Mac and so names /tmp's directory
    /// "-tmp" where Claude Code has "-private-tmp". Any other path is
    /// given back as it is.
    static func realPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var resolved = ""
        var pending = path.split(separator: "/").map(String.init)
        var links = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." { continue }
            if part == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                if resolved == "/" { resolved = "" }
                continue
            }
            let candidate = resolved + "/" + part
            // A loop of links goes no further than realpath would.
            if links < 40, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                links += 1
                if target.hasPrefix("/") { resolved = "" }
                pending = target.split(separator: "/").map(String.init) + pending
            } else {
                resolved = candidate
            }
        }
        return resolved.isEmpty ? "/" : resolved
    }

    /// Where a session's file should be, whether or not it exists yet.
    public static func expectedURL(sessionID: String, cwd: String, home: URL = ClaudeSessionFiles.home) -> URL {
        projectsRoot(home: home).appendingPathComponent(projectDirectoryName(for: cwd)).appendingPathComponent(sessionID + ".jsonl")
    }

    /// A session's file: under its folder's directory, or wherever it is.
    public static func locate(sessionID: String, cwd: String, home: URL = ClaudeSessionFiles.home) -> URL? {
        let expected = expectedURL(sessionID: sessionID, cwd: cwd, home: home)
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        let root = projectsRoot(home: home)
        for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let candidate = directory.appendingPathComponent(sessionID + ".jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
