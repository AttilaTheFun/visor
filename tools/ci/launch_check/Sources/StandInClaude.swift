import Foundation

/// The `claude` the app finds while it is checked: it answers the server's
/// model probe (ClaudeHarness.refreshModels, the `initialize` control
/// request) at once with one model, then sleeps until it is ended, as the
/// probe ends it. No Claude Code, no account, no turn: the server starts
/// as it does on a Mac with Claude Code installed.
///
/// It goes where ToolPath.resolve looks: a folder of its own, put first on
/// the PATH the app is opened with, and ~/.local/bin/claude, one of the
/// Mac's usual folders. A `claude` already at the latter is moved aside
/// and put back by `remove()`.
struct StandInClaude {
    /// The answer, as Claude Code gives it: one model, the default.
    static let answer = #"{"type":"control_response","response":{"subtype":"success","request_id":"visor-models","response":{"models":[{"value":"default","displayName":"Default","description":"d"}]}}}"#
    static let marker = "# launch_check's stand-in claude"
    static let script = """
        #!/bin/sh
        \(marker)
        read -r line
        printf '%s\\n' '\(answer)'
        exec sleep 300

        """

    /// The folder to put first on the app's PATH.
    let folder: URL
    let local: URL
    /// Where a `claude` that was at `local` was moved, to be put back.
    let movedAside: URL?

    /// Writes the stand-in into `work`/bin and at ~/.local/bin/claude.
    static func install(in work: URL) throws -> StandInClaude {
        let files = FileManager.default
        let folder = work.appendingPathComponent("bin")
        let local = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")
        var movedAside: URL?
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            // attributesOfItem, not fileExists: a link to nothing is there too.
            if (try? files.attributesOfItem(atPath: local.path)) != nil {
                let text = (try? String(contentsOf: local, encoding: .utf8)) ?? ""
                if text.contains(marker) {
                    try files.removeItem(at: local)
                } else {
                    let aside = local.deletingLastPathComponent().appendingPathComponent("claude.launch_check-\(getpid())")
                    try files.moveItem(at: local, to: aside)
                    movedAside = aside
                }
            }
            for url in [folder.appendingPathComponent("claude"), local] {
                try Data(script.utf8).write(to: url)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        } catch {
            if let movedAside { try? files.moveItem(at: movedAside, to: local) }
            throw LaunchCheckError.setup("the stand-in claude couldn't be installed: \(error.localizedDescription)")
        }
        return StandInClaude(folder: folder, local: local, movedAside: movedAside)
    }

    /// ~/.local/bin/claude as it was. The folder goes with the work folder.
    func remove() {
        try? FileManager.default.removeItem(at: local)
        if let movedAside { try? FileManager.default.moveItem(at: movedAside, to: local) }
    }
}
