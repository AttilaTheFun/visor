// Sessions given another working directory, their agents' conversations
// kept (Shireworks' docs/volumes.md §6): the co-tenant's sessions, made in
// folders of the Mac's, moved to /Volumes/Sessions as they go into a
// primary container. `visor-server move-folder`, run once with the server
// stopped. What it changes:
//
// - Visor's records (sessions.json and the copy beside it): each session's
//   folder and its resume command.
// - Claude Code's store (FolderMove+Claude): each old folder's project
//   (`~/.claude/projects/<key>/`: transcripts, their folders, memory)
//   merged into the new folder's, the prompt history's projects, and
//   ~/.claude.json's per-project entries.
// - Codex's (FolderMove+Codex): each rollout's recorded folder.

import Foundation

/// A move of sessions to one working directory, planned and then applied.
public struct FolderMove: Sendable {
    /// The new working directory.
    public var target: String
    /// The agents' home: `.claude`, `.claude.json`, `.codex`.
    public var home: URL
    /// The server's data folder: `sessions.json`.
    public var data: URL
    /// Only the sessions in these folders or under them; nil: every one.
    public var from: [String]?

    public init(target: String, home: URL, data: URL, from: [String]? = nil) {
        self.target = Self.normalized(target)
        self.home = home
        self.data = data
        self.from = from.map { $0.map(Self.normalized) }
    }

    /// A session to be moved.
    public struct Session: Sendable, Equatable {
        public var id: String
        public var title: String
        public var agent: String
        public var folder: String
        /// Its agent's conversation, found where the old folder keeps it
        /// (Claude: the project's `<id>.jsonl`; Codex: a rollout); nil when
        /// it has none to look for (no agent id yet).
        public var conversationFound: Bool?
    }

    /// What a move would change.
    public struct Plan: Sendable, Equatable {
        public var sessions: [Session] = []
        /// Claude Code's projects to merge into the target's, by key.
        public var claudeProjects: [String] = []
        /// Claude's projects whose folder no session moved names: left.
        public var claudeProjectsLeft: [String] = []
        /// Memory files whose names clash, each with its new name.
        public var memoryRenames: [String: String] = [:]
        public var historyLines = 0
        public var claudeConfigProjects: [String] = []
        public var codexRollouts: [String] = []

        /// The old folders, each once.
        public var folders: [String] { Array(Set(sessions.map(\.folder))).sorted() }
    }

    /// The plan, read from the files as they are; changes nothing.
    public func plan() throws -> Plan {
        var plan = Plan()
        let stored = try readSessions(sessionsURL)
        for session in stored where moves(session.info.cwd) {
            plan.sessions.append(Session(id: session.info.id, title: session.info.title, agent: session.info.agent.rawValue,
                                         folder: session.info.cwd, conversationFound: conversationFound(session)))
        }
        planClaude(&plan)
        planCodex(&plan)
        return plan
    }

    /// Carries the plan out; what was done, a line each.
    @discardableResult
    public func apply(_ plan: Plan) throws -> [String] {
        var done: [String] = []
        let folders = Set(plan.folders)
        for file in [sessionsURL, previousURL] where FileManager.default.fileExists(atPath: file.path) {
            let count = try rewriteSessions(file, folders: folders)
            done.append("\(file.lastPathComponent): \(count) sessions given \(target)")
        }
        done += try applyClaude(plan)
        done += try applyCodex(plan)
        return done
    }

    /// The plan as lines for a person.
    public static func describe(_ plan: Plan, target: String) -> [String] {
        var lines = ["\(plan.sessions.count) sessions to \(target):"]
        for session in plan.sessions {
            let found = session.conversationFound.map { $0 ? "conversation found" : "CONVERSATION NOT FOUND" } ?? "no conversation yet"
            lines.append("  \(session.id) \(session.agent) \"\(session.title)\" from \(session.folder) (\(found))")
        }
        lines.append("Claude projects merged into \(claudeKey(target)): " + (plan.claudeProjects.isEmpty ? "none" : plan.claudeProjects.joined(separator: ", ")))
        if !plan.claudeProjectsLeft.isEmpty { lines.append("Claude projects left (no session moved names them): " + plan.claudeProjectsLeft.joined(separator: ", ")) }
        for (old, new) in plan.memoryRenames.sorted(by: { $0.key < $1.key }) { lines.append("  memory \(old) → \(new) (its name is taken)") }
        lines.append("Prompt history: \(plan.historyLines) lines; ~/.claude.json projects: \(plan.claudeConfigProjects.count); Codex rollouts: \(plan.codexRollouts.count)")
        return lines
    }

    // MARK: Visor's records

    var sessionsURL: URL { data.appendingPathComponent("sessions.json", isDirectory: false) }
    var previousURL: URL { data.appendingPathComponent("sessions.previous.json", isDirectory: false) }

    /// Whether a session in `folder` is moved.
    func moves(_ folder: String) -> Bool {
        let folder = Self.normalized(folder)
        guard folder != target else { return false }
        guard let from else { return true }
        return from.contains { folder == $0 || folder.hasPrefix($0 + "/") }
    }

    func readSessions(_ file: URL) throws -> [StoredSession] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([StoredSession].self, from: Data(contentsOf: file))
    }

    /// Each moved session given the target, its resume command with it;
    /// written as the server writes it. How many were moved.
    func rewriteSessions(_ file: URL, folders: Set<String>) throws -> Int {
        var stored = try readSessions(file)
        var count = 0
        for index in stored.indices where folders.contains(stored[index].info.cwd) && moves(stored[index].info.cwd) {
            let old = stored[index].info.cwd
            stored[index].info.cwd = target
            if let command = stored[index].info.resumeCommand, command.hasPrefix("cd \(old) && ") {
                stored[index].info.resumeCommand = "cd \(target) && " + command.dropFirst("cd \(old) && ".count)
            }
            count += 1
        }
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
        return count
    }

    func conversationFound(_ session: StoredSession) -> Bool? {
        guard let id = session.resumeID, !id.isEmpty else { return nil }
        switch session.info.agent {
        case .codex: return codexRollout(for: id) != nil
        case .claude:
            let project = claudeProjects.appendingPathComponent(Self.claudeKey(session.info.cwd), isDirectory: true)
            return FileManager.default.fileExists(atPath: project.appendingPathComponent(id + ".jsonl").path)
        // The OpenRouter CLI keeps its own, which no folder names.
        case .openrouter: return nil
        }
    }

    /// Without a trailing slash ("/" itself kept).
    static func normalized(_ folder: String) -> String {
        var folder = folder
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        return folder
    }
}
