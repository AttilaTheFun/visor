// Where Claude Code keeps a session: ~/.claude/projects/<the folder's path
// with "/", "." and "_" as "-">/<session id>.jsonl. The folder is fixed
// when the session starts and kept through renames, so a session whose
// folder moved is looked for everywhere before it is given up on.

import Foundation

public enum ClaudeSessionFiles {
    /// Whose home the sessions are under: the user's, unless a test says.
    public static var home = FileManager.default.homeDirectoryForCurrentUser

    public static func projectsRoot(home: URL = ClaudeSessionFiles.home) -> URL {
        home.appendingPathComponent(".claude/projects")
    }

    /// The project directory's name for a folder.
    public static func projectDirectoryName(for cwd: String) -> String {
        // The folder as Claude Code sees it: the real path, then every
        // "/", "." and "_" as "-". POSIX realpath, not Foundation's
        // resolvingSymlinksInPath, which strips "/private" on a Mac and so
        // names /tmp's directory "-tmp" where Claude Code has "-private-tmp".
        let expanded = (cwd as NSString).expandingTildeInPath
        var name = expanded
        if let resolved = realpath(expanded, nil) {
            name = String(cString: resolved)
            free(resolved)
        }
        for character in ["/", ".", "_"] { name = name.replacingOccurrences(of: character, with: "-") }
        return name
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
