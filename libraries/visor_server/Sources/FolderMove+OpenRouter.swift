// The OpenRouter CLI's store moved with its sessions: a JSON file per
// session (`~/.openrouter/sessions/<id>.json`, its OpenRouterKit's
// ORSession) whose `cwd` is the folder it runs in, and which a resume
// without a folder of its own runs in again. A moved session's is given the
// new folder as the CLI keeps one (`ORSession.folder`: absolute, its links
// followed). The log beside it (`<id>.jsonl`) is messages alone, no folder:
// it stays as it was.

import ClaudeTranscript
import Foundation

extension FolderMove {
    var openRouterSessions: URL { openRouter.appendingPathComponent("sessions", isDirectory: true) }

    /// The session file of the CLI's session `id`, where there is one; nil
    /// for an id that names no file in the folder (as the CLI's own
    /// `ORSessionStore.isValid` refuses it).
    func openRouterSession(for id: String) -> URL? {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/") else { return nil }
        let file = openRouterSessions.appendingPathComponent(id + ".json", isDirectory: false)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func planOpenRouter(_ plan: inout Plan, _ stored: [StoredSession]) {
        let moved = Set(plan.sessions.map(\.id))
        plan.openRouterSessions = stored.filter { moved.contains($0.info.id) && $0.info.agent == .openrouter }
            .compactMap { $0.resumeID.flatMap { id in openRouterSession(for: id) }?.path }
    }

    func applyOpenRouter(_ plan: Plan) throws -> [String] {
        for path in plan.openRouterSessions { try rewriteOpenRouterSession(URL(fileURLWithPath: path), folder: target) }
        return plan.openRouterSessions.isEmpty ? [] : ["OpenRouter: \(plan.openRouterSessions.count) sessions given \(target)"]
    }

    /// The session file's `cwd` made `folder`, as the CLI spells one; the
    /// rest of it as it was (its keys sorted, as the CLI writes them).
    func rewriteOpenRouterSession(_ file: URL, folder: String) throws {
        guard var session = (try JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] else { return }
        session["cwd"] = ClaudeSessionFiles.realPath(folder)
        try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file, options: .atomic)
    }
}
