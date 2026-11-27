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
    package static func agentFolder(_ agent: AgentKind) -> URL? {
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
            // Each as it is, never a link followed: the transcript a plain
            // file, the folder beside it a folder, in a project whose real
            // path is inside Claude's projects folder. (A link would be read
            // as the user, wherever it led.)
            let kind = { (url: URL) in (try? files.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType }
            guard let folder = folders.first(where: {
                kind($0.appendingPathComponent(id + ".jsonl", isDirectory: false)) == .typeRegular
                    && ClaudeSessionFiles.isInsideProjects($0.path)
            }) else { return [] }
            var found = [ConversationFile(url: folder.appendingPathComponent(id + ".jsonl", isDirectory: false),
                                          place: "projects/{project}/\(id).jsonl", folder: false)]
            // What its subagents and long tool results were kept in.
            let beside = folder.appendingPathComponent(id, isDirectory: true)
            if kind(beside) == .typeDirectory {
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

    /// Whether `id` is shaped as a conversation's id is by every agent
    /// Visor runs: a UUID, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` in hex
    /// (Claude Code's session ids, Codex's thread ids, and the openrouter
    /// CLI's, which it makes as `UUID().uuidString.lowercased()`). Nothing
    /// else the agent keeps beside a conversation, such as Claude's
    /// `memory` folder or a Codex file named `rollout`, has that shape.
    package static func isConversationID(_ id: String) -> Bool {
        let characters = Array(id.utf8)
        guard characters.count == 36 else { return false }
        for (index, character) in characters.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard character == UInt8(ascii: "-") else { return false }
            } else {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(character) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(character)
                    || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(character) else { return false }
            }
        }
        return true
    }

    /// Whether `name` is Codex's rollout file for the thread `id`, exactly
    /// as Codex names one: `rollout-<stamp>-<id>.jsonl`, its stamp when the
    /// thread began (`2026-10-04T00-59-02`).
    package static func isCodexRollout(_ name: String, id: String) -> Bool {
        let prefix = "rollout-", suffix = "-" + id + ".jsonl"
        guard !id.isEmpty, name.hasPrefix(prefix), name.hasSuffix(suffix), name.count == prefix.count + 19 + suffix.count else { return false }
        let stamp = Array(name.dropFirst(prefix.count).prefix(19).utf8)
        for (index, character) in stamp.enumerated() {
            let shaped = switch index {
            case 4, 7, 13, 16: character == UInt8(ascii: "-")
            case 10: character == UInt8(ascii: "T")
            default: (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(character)
            }
            guard shaped else { return false }
        }
        return true
    }

    /// Where a file the move carried goes here, for a session in `cwd` on
    /// the conversation `resume` (a conversation's id, isConversationID):
    /// under the agent's folder, and only where the agent keeps that
    /// conversation, as conversationFiles names it (Claude's
    /// `projects/{project}/<resume>.jsonl` and the folder `<resume>` beside
    /// it, Codex's `sessions/<year>/<month>/<day>/rollout-<stamp>-<resume>.jsonl`,
    /// OpenRouter's `sessions/<resume>.json` or `.jsonl`). Nil for any other
    /// place, such as the agent's settings or credentials, Claude's memory or
    /// another conversation, and for one that would lead out of its folder:
    /// a place is the other server's word.
    package static func destination(of place: String, agent: AgentKind, cwd: String, resume: String) -> URL? {
        guard let root = agentFolder(agent), isConversationID(resume) else { return nil }
        let parts = place.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let digits = { (part: String, count: Int) in part.count == count && part.allSatisfy { $0.isASCII && $0.isNumber } }
        let shaped = switch agent {
        case .claude: parts.count == 3 && parts[0] == "projects" && parts[1] == "{project}" && [resume, resume + ".jsonl"].contains(parts[2])
        case .codex: parts.count == 5 && parts[0] == "sessions" && digits(parts[1], 4) && digits(parts[2], 2) && digits(parts[3], 2)
            && isCodexRollout(parts[4], id: resume)
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
