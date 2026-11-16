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
        case .codex: codexRoot()
        case .openrouter: openrouterRoot
        }
    }

    /// What holds the conversation `id` of a session in `cwd`.
    package static func conversationFiles(agent: AgentKind, id: String, cwd: String) -> [ConversationFile] {
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
        }
    }

    /// Where a file the move carried goes here, for a session in `cwd` on
    /// the conversation `resume`: under the agent's folder, and only where
    /// the agent keeps that conversation, as conversationFiles names it
    /// (Claude's `projects/{project}/<resume>.jsonl` and the folder
    /// `<resume>` beside it, Codex's `sessions/…/rollout-…<resume>….jsonl`,
    /// OpenRouter's `sessions/<resume>.json` or `.jsonl`). Nil for any other
    /// place, such as the agent's settings or credentials, and for one that
    /// would lead out of its folder: a place is the other server's word.
    package static func destination(of place: String, agent: AgentKind, cwd: String, resume: String) -> URL? {
        guard let root = agentFolder(agent), !resume.isEmpty else { return nil }
        let parts = place.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let shaped = switch agent {
        case .claude: parts.count == 3 && parts[0] == "projects" && parts[1] == "{project}" && [resume, resume + ".jsonl"].contains(parts[2])
        case .codex: parts.count >= 2 && parts[0] == "sessions" && parts.last.map { $0.hasSuffix(".jsonl") && $0.contains(resume) } == true
        case .openrouter: parts.count == 2 && parts[0] == "sessions" && [resume + ".json", resume + ".jsonl"].contains(parts[1])
        }
        guard shaped else { return nil }
        let resolved = parts.map { $0 == "{project}" ? ClaudeSessionFiles.projectDirectoryName(for: cwd) : $0 }
        guard resolved.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") }) else { return nil }
        let url = resolved.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
        let inner = url.standardizedFileURL.pathComponents, outer = root.standardizedFileURL.pathComponents
        return inner.count > outer.count && Array(inner.prefix(outer.count)) == outer ? url : nil
    }

    private static func relative(_ file: URL, to root: URL) -> String? {
        let path = file.standardizedFileURL.path, base = root.standardizedFileURL.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }
}
