// A moved session's conversation as the driver hands it to its runner's
// wrapper (AgentDriver.Conversation): the files a move to another computer
// takes (SessionCatalog.conversationFiles: the conversation, and what its
// subagents kept beside it), a folder's file by file, and the project's
// memory (where Claude Code keeps it here: ClaudeSessionFiles.memoryFolder,
// beside the conversation or under the project of the folder's repository
// or of the folder, a link to it followed), each with its place under
// Claude's folder for the folder the session will work in there: the
// memory under the project Claude Code keeps that folder's memory under.

import ClaudeTranscript
import Foundation
import VisorAgent
import VisorProtocol
import VisorServer

enum ConversationFiles {
    /// How much of a file goes in one piece.
    static let piece = 1 << 20

    struct File: Equatable {
        let place: String
        let url: URL
    }

    /// The conversation `resume` of a session that worked in `cwd` here,
    /// placed for a session working in `workingDirectory` on the runner.
    static func of(resume: String, cwd: String, for workingDirectory: String) -> [File] {
        let project = ClaudeSessionFiles.projectDirectoryName(for: workingDirectory)
        var found: [File] = []
        var conversation: URL?
        for file in SessionCatalog.conversationFiles(agent: .claude, id: resume, cwd: cwd) {
            let place = file.place.replacingOccurrences(of: "{project}", with: project)
            if file.folder {
                found += files(in: file.url).map { File(place: place + "/" + $0.relative, url: $0.url) }
            } else {
                found.append(File(place: place, url: file.url))
                if conversation == nil { conversation = file.url }
            }
        }
        // The project's memory, where Claude Code keeps it.
        let refused = { (why: String) in VisorServer.log("driver: a memory refused: \(why)") }
        if let conversation, let memory = ClaudeSessionFiles.memoryFolder(conversation: conversation, cwd: cwd, refused: refused) {
            let there = ClaudeSessionFiles.memoryProjectDirectoryName(for: workingDirectory)
            found += files(in: memory).map { File(place: "projects/\(there)/memory/\($0.relative)", url: $0.url) }
        }
        return found
    }

    /// The files under `folder`, each with its path relative to it: plain
    /// files alone, never a link (looked at as it is, not followed), so one
    /// inside that leads out of it is never read and sent.
    static func files(in folder: URL) -> [(relative: String, url: URL)] {
        let root = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var found: [(String, URL)] = []
        for case let url as URL in walker {
            guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            found.append((String(path.dropFirst(root.count + 1)), url))
        }
        return found.sorted { $0.0 < $1.0 }
    }
}
