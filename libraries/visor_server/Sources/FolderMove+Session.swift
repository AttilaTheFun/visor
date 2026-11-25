// One session given another working directory, the rest left where they
// are: what a session's inspector changes (the server ends its agent, moves
// it, writes its record and resumes it there), and `visor-server
// move-folder --session <id>` with the server stopped. Its own conversation
// goes with it, by id; what it shares with the sessions it leaves behind is
// copied to the new folder, not taken from them:
//
// - Claude Code: the transcript (`<id>.jsonl`) and its folder (`<id>/`:
//   subagents, tool results) move from the project they're in to the one
//   Claude Code keeps for the new folder. The old project's memory and
//   ~/.claude.json's entry for the old folder are copied, merged as a
//   folder's move merges them (FolderMove+Claude), while another session of
//   Visor's still names that project; with none left, they move. The
//   prompt history is left as it is: it's history, not state.
// - Codex: the thread's rollout, its session meta given the new folder
//   (Codex resumes by thread id; the folder there is a record).
// - The OpenRouter CLI: the session file, given the new folder.
// - Visor's record: its folder and resume command, given back
//   (`moved(_:to:)`, the plan's `session`) for the caller to write.
//
// Nothing is deleted before the transcript is in its new project: it moves
// first, by a rename within ~/.claude/projects, after every name it moves to
// is seen to be free. A failure there stops the move with nothing changed.

import ClaudeTranscript
import Foundation
import VisorProtocol
import VisorSystem

/// Why a session can't be given a folder.
public enum FolderMoveError: Error, Equatable, LocalizedError {
    /// Not a path from the root ("~" aside).
    case notAbsolute(String)
    case missing(String)
    case notAFolder(String)
    case unreadable(String)
    /// The folder it's in already, by the same name.
    case sameFolder(String)
    case noSession(String)
    /// A file of the conversation's is in the new project already.
    case taken(String)

    public var errorDescription: String? {
        switch self {
        case .notAbsolute(let path): "\(path) is not a full path (one from /)."
        case .missing(let path): "There is no \(path)."
        case .notAFolder(let path): "\(path) is a file, not a folder."
        case .unreadable(let path): "\(path) can't be read."
        case .sameFolder(let path): "The session is in \(path) already."
        case .noSession(let id): "There is no session \(id)."
        case .taken(let path): "\(path) is there already: the conversation was not moved."
        }
    }
}

extension FolderMove {
    /// What moving one session would change.
    public struct SessionPlan: Sendable, Equatable {
        /// Visor's session as it will be: its new folder and resume command.
        public var session: SessionInfo
        /// The folder it leaves.
        public var from: String
        /// Its agent's own id for the conversation: Claude Code's session,
        /// Codex's thread, the OpenRouter CLI's session; nil before it has
        /// one.
        public var resumeID: String?
        /// Claude Code's project the conversation is in, and the one for the
        /// new folder, by key; nil for another agent's session. The same
        /// key twice where the new folder is the old one under another name
        /// as Claude Code sees it: nothing of Claude's moves.
        public var claudeFrom: String?
        public var claudeTo: String?
        /// What moves from the one project to the other: `<id>.jsonl`, and
        /// `<id>` where it has a folder.
        public var claudeFiles: [String] = []
        /// Visor's other sessions in the old project, by id: while there are
        /// any, its memory and ~/.claude.json's entry are copied, not moved.
        public var sharedWith: [String] = []
        /// The memory files brought to the new project (MEMORY.md aside),
        /// and those of them whose names are taken there, each with its new
        /// name (by `<key>/memory/<name>`).
        public var memoryFiles: [String] = []
        public var memoryRenames: [String: String] = [:]
        /// ~/.claude.json has an entry for the old folder.
        public var claudeConfigEntry = false
        /// The Codex thread's rollout, and the OpenRouter CLI's session
        /// file, given the new folder.
        public var codexRollout: String?
        public var openRouterSession: String?

        /// Another session still uses the old project.
        public var shared: Bool { !sharedWith.isEmpty }
    }

    /// The folder a session can be given, as it's kept (absolute, without
    /// a trailing slash): one that exists, is a folder and can be read,
    /// other than `current`. The same folder by another name is allowed (a
    /// link to it, or the name it has now that the old one is a link to
    /// it): Claude Code keeps its project by the name, so that's a move.
    public static func checkFolder(_ folder: String, from current: String) throws -> String {
        let resolved = normalized(HostFolders.resolve(folder.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard resolved.hasPrefix("/") else { throw FolderMoveError.notAbsolute(folder) }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isFolder) else { throw FolderMoveError.missing(resolved) }
        guard isFolder.boolValue else { throw FolderMoveError.notAFolder(resolved) }
        guard FileManager.default.isReadableFile(atPath: resolved) else { throw FolderMoveError.unreadable(resolved) }
        guard resolved != normalized(HostFolders.resolve(current)) else { throw FolderMoveError.sameFolder(resolved) }
        return resolved
    }

    /// The session as it is in `folder`: its folder, and its resume
    /// command's (`cd <folder> && …`); the rest as it was.
    public static func moved(_ info: SessionInfo, to folder: String) -> SessionInfo {
        var moved = info
        moved.cwd = folder
        if let command = info.resumeCommand {
            // As the agents' processes write it: quoted where it has a space.
            for old in [quoted(info.cwd), info.cwd] where command.hasPrefix("cd \(old) && ") {
                moved.resumeCommand = "cd \(quoted(folder)) && " + command.dropFirst("cd \(old) && ".count)
                break
            }
        }
        return moved
    }

    static func quoted(_ path: String) -> String { path.contains(" ") ? "'\(path)'" : path }

    /// The plan for one session, given to `target`: `resumeID` its agent's
    /// id for the conversation, `others` the rest of Visor's sessions (what
    /// tells whether the old project is shared). Changes nothing.
    public func planSession(_ session: SessionInfo, resumeID: String?, others: [SessionInfo]) throws -> SessionPlan {
        let folder = try Self.checkFolder(target, from: session.cwd)
        let resumeID = resumeID.flatMap { $0.isEmpty ? nil : $0 }
        var plan = SessionPlan(session: Self.moved(session, to: folder), from: Self.normalized(HostFolders.resolve(session.cwd)), resumeID: resumeID)
        switch session.agent {
        case .claude: planClaudeSession(&plan, others: others.filter { $0.id != session.id })
        case .codex:
            plan.codexRollout = resumeID.flatMap { codexRollout(for: $0) }.flatMap { file in
                Self.metaFolder(Self.firstLine(file)) == folder ? nil : file.path
            }
        case .openrouter: plan.openRouterSession = resumeID.flatMap { openRouterSession(for: $0) }?.path
        }
        return plan
    }

    /// The plan for the session `id` in the data folder's sessions.json
    /// (the server stopped), the rest of them read from there too.
    public func planSession(id: String) throws -> SessionPlan {
        let stored = try readSessions(sessionsURL)
        guard let session = stored.first(where: { $0.info.id == id }) else { throw FolderMoveError.noSession(id) }
        return try planSession(session.info, resumeID: session.resumeID, others: stored.map(\.info))
    }

    /// Carries a session's plan out: its agent's files, not Visor's record
    /// (`writeRecord` with the server stopped; the server's own otherwise).
    /// What was done, a line each.
    @discardableResult
    public func applySession(_ plan: SessionPlan) throws -> [String] {
        var done = try applyClaudeSession(plan)
        if let path = plan.codexRollout {
            try rewriteRollout(URL(fileURLWithPath: path), folder: plan.session.cwd)
            done.append("Codex: the rollout given \(plan.session.cwd)")
        }
        if let path = plan.openRouterSession {
            try rewriteOpenRouterSession(URL(fileURLWithPath: path), folder: plan.session.cwd)
            done.append("OpenRouter: the session given \(plan.session.cwd)")
        }
        return done
    }

    /// The session's record in sessions.json and the copy beside it given
    /// the plan's folder and resume command, as the server writes them.
    @discardableResult
    public func writeRecord(_ plan: SessionPlan) throws -> [String] {
        var done: [String] = []
        for file in [sessionsURL, previousURL] where FileManager.default.fileExists(atPath: file.path) {
            var stored = try readSessions(file)
            guard let index = stored.firstIndex(where: { $0.info.id == plan.session.id }) else { continue }
            stored[index].info = Self.moved(stored[index].info, to: plan.session.cwd)
            try JSONEncoder().encode(stored).write(to: file, options: .atomic)
            done.append("\(file.lastPathComponent): the session given \(plan.session.cwd)")
        }
        return done
    }

    /// A session's plan as lines for a person.
    public static func describe(_ plan: SessionPlan) -> [String] {
        let session = plan.session
        var lines = ["\(session.id) \(session.agent.rawValue) \"\(session.title)\" from \(plan.from) to \(session.cwd):"]
        if let from = plan.claudeFrom, let to = plan.claudeTo {
            if from == to {
                lines.append("  Claude project \(to): the new folder's already; nothing in it moves")
            } else {
                let files = plan.claudeFiles.isEmpty ? "no conversation found" : plan.claudeFiles.joined(separator: ", ") + " moved"
                lines.append("  Claude project \(from) → \(to): \(files)")
                let how = plan.shared ? "copied (\(plan.sharedWith.joined(separator: ", ")) still there)" : "moved (no other session there)"
                lines.append("  memory: \(plan.memoryFiles.count) files \(how)")
                for (old, new) in plan.memoryRenames.sorted(by: { $0.key < $1.key }) { lines.append("    \(old) → \(new) (its name is taken)") }
                if plan.claudeConfigEntry { lines.append("  ~/.claude.json: \(plan.from)'s entry " + (plan.shared ? "copied" : "moved")) }
            }
        }
        if let path = plan.codexRollout { lines.append("  Codex rollout \(path) given the folder") }
        if let path = plan.openRouterSession { lines.append("  OpenRouter session \(path) given the folder") }
        lines.append("  Visor's record: " + (session.resumeCommand ?? session.cwd))
        return lines
    }

    // MARK: Claude Code

    /// The project a Claude Code session's transcript is in: the old
    /// folder's, by its name or as Claude Code sees it, or wherever else it
    /// is (a folder renamed since it started).
    func claudeProject(of id: String, folder: String) -> String? {
        let manager = FileManager.default
        let named = [Self.claudeKey(folder), Self.claudeProjectKey(folder)]
        let others = ((try? manager.contentsOfDirectory(atPath: claudeProjects.path)) ?? []).sorted()
        return (named + others).first { key in
            manager.fileExists(atPath: claudeProjects.appendingPathComponent(key, isDirectory: true).appendingPathComponent(id + ".jsonl").path)
        }
    }

    func planClaudeSession(_ plan: inout SessionPlan, others: [SessionInfo]) {
        let manager = FileManager.default
        let from = plan.from
        let found = plan.resumeID.flatMap { claudeProject(of: $0, folder: from) }
        let source = found ?? Self.claudeProjectKey(from)
        let destination = Self.claudeProjectKey(plan.session.cwd)
        plan.claudeFrom = source
        plan.claudeTo = destination
        guard source != destination else { return }
        let project = claudeProjects.appendingPathComponent(source, isDirectory: true)
        if found != nil, let id = plan.resumeID {
            plan.claudeFiles = [id + ".jsonl"] + (manager.fileExists(atPath: project.appendingPathComponent(id).path) ? [id] : [])
        }
        plan.sharedWith = others.filter { other in
            let folder = HostFolders.resolve(other.cwd)
            return Self.claudeKey(Self.normalized(folder)) == source || Self.claudeProjectKey(folder) == source
        }.map(\.id)
        let memory = project.appendingPathComponent("memory", isDirectory: true)
        plan.memoryFiles = ((try? manager.contentsOfDirectory(atPath: memory.path)) ?? []).filter { $0 != "MEMORY.md" }.sorted()
        plan.memoryRenames = memoryRenames([source], folders: [plan.from], into: claudeMemory(destination))
        plan.claudeConfigEntry = !claudeConfigProjects([plan.from]).isEmpty
    }

    func claudeMemory(_ key: String) -> URL {
        claudeProjects.appendingPathComponent(key, isDirectory: true).appendingPathComponent("memory", isDirectory: true)
    }

    func applyClaudeSession(_ plan: SessionPlan) throws -> [String] {
        guard let source = plan.claudeFrom, let destination = plan.claudeTo, source != destination else { return [] }
        let manager = FileManager.default
        let from = claudeProjects.appendingPathComponent(source, isDirectory: true)
        let to = claudeProjects.appendingPathComponent(destination, isDirectory: true)
        var done: [String] = []
        // The conversation first, every name it goes to seen to be free
        // before anything moves: until it's there, nothing is deleted.
        for name in plan.claudeFiles where manager.fileExists(atPath: to.appendingPathComponent(name).path) {
            throw FolderMoveError.taken(to.appendingPathComponent(name).path)
        }
        try manager.createDirectory(at: to, withIntermediateDirectories: true)
        for name in plan.claudeFiles { try manager.moveItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name)) }
        if !plan.claudeFiles.isEmpty { done.append("Claude: \(plan.claudeFiles.joined(separator: ", ")) moved from \(source) to \(destination)") }
        let how = plan.shared ? "copied" : "moved"
        if manager.fileExists(atPath: claudeMemory(source).path) {
            try mergeMemory([source], folders: [plan.from], into: claudeMemory(destination), copying: plan.shared)
            done.append("Claude: memory \(how) (\(plan.memoryFiles.count) files" + (plan.memoryRenames.isEmpty ? ")" : ", \(plan.memoryRenames.count) renamed)"))
        }
        if try carryClaudeConfig(from: plan.from, to: Self.claudeFolder(plan.session.cwd), copying: plan.shared) {
            done.append("~/.claude.json: \(plan.from)'s entry \(how)")
        }
        // The old project, left with nothing, goes too.
        if !plan.shared, (try? manager.contentsOfDirectory(atPath: from.path))?.isEmpty == true { try manager.removeItem(at: from) }
        return done
    }
}
