// A conversation's files as a move to another computer takes them (the
// agents' own stores, as SessionCatalog reads them): each found here by
// the conversation's id, and put where the same agent there looks for it.
// Claude keeps a session under a folder named for the project's path, so
// that part of where it goes is the project's name there (`{project}`).

import ClaudeTranscript
import Foundation
import VisorProtocol

extension SessionCatalog {
    /// The agent's own folder, which a file's place is under.
    static func agentFolder(_ agent: AgentKind) -> URL? {
        switch agent {
        case .claude: ClaudeSessionFiles.configDirectory()
        case .codex: home.appendingPathComponent(".codex", isDirectory: true)
        case .openrouter: openrouterRoot
        case .shell: nil
        }
    }

    /// What holds the conversation `id` of a session in `cwd`.
    static func conversationFiles(agent: AgentKind, id: String, cwd: String) -> [ConversationFile] {
        let files = FileManager.default
        switch agent {
        case .claude:
            let root = ClaudeSessionFiles.projectsRoot()
            let named = root.appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd), isDirectory: true)
            let folders = [named] + ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            guard let folder = folders.first(where: { files.fileExists(atPath: $0.appendingPathComponent(id + ".jsonl", isDirectory: false).path) })
            else { return [] }
            var found = [ConversationFile(url: folder.appendingPathComponent(id + ".jsonl", isDirectory: false),
                                          place: "projects/{project}/\(id).jsonl", folder: false)]
            // What its subagents and long tool results were kept in.
            let beside = folder.appendingPathComponent(id, isDirectory: true)
            var isFolder: ObjCBool = false
            if files.fileExists(atPath: beside.path, isDirectory: &isFolder), isFolder.boolValue {
                found.append(ConversationFile(url: beside, place: "projects/{project}/\(id)", folder: true))
            }
            return found
        case .codex:
            guard let rollout = codexRollout(id: id), let root = agentFolder(.codex),
                  let place = relative(rollout, to: root) else { return [] }
            return [ConversationFile(url: rollout, place: place, folder: false)]
        case .openrouter:
            let sessions = openrouterRoot.appendingPathComponent("sessions", isDirectory: true)
            return ["json", "jsonl"].compactMap { suffix in
                let file = sessions.appendingPathComponent("\(id).\(suffix)", isDirectory: false)
                return files.fileExists(atPath: file.path) ? ConversationFile(url: file, place: "sessions/\(id).\(suffix)", folder: false) : nil
            }
        case .shell:
            return []
        }
    }

    /// Where a file the move carried goes here, for a session in `cwd`;
    /// nil for a place that would lead out of the agent's folder.
    static func destination(of place: String, agent: AgentKind, cwd: String) -> URL? {
        guard let root = agentFolder(agent), !place.isEmpty else { return nil }
        let resolved = place.replacingOccurrences(of: "{project}", with: ClaudeSessionFiles.projectDirectoryName(for: cwd))
        let parts = resolved.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
    }

    private static func relative(_ file: URL, to root: URL) -> String? {
        let path = file.standardizedFileURL.path, base = root.standardizedFileURL.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }
}
