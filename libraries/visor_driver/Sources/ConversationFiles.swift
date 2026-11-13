// A moved session's conversation as the driver hands it to its runner's
// wrapper (AgentDriver.Conversation): the files a move to another computer
// takes (SessionCatalog.conversationFiles: the conversation, and what its
// subagents kept beside it), a folder's file by file, and the project's
// memory (`memory/` beside the conversation), each with its place under
// Claude's folder for the folder the session will work in there.

import ClaudeTranscript
import Foundation
import VisorAgent
import VisorProtocol

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
        // The project's memory, beside the conversation.
        if let conversation {
            let memory = conversation.deletingLastPathComponent().appendingPathComponent("memory", isDirectory: true)
            found += files(in: memory).map { File(place: "projects/\(project)/memory/\($0.relative)", url: $0.url) }
        }
        return found
    }

    /// The files under `folder`, each with its path relative to it.
    static func files(in folder: URL) -> [(relative: String, url: URL)] {
        let root = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var found: [(String, URL)] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            found.append((String(path.dropFirst(root.count + 1)), url))
        }
        return found.sorted { $0.0 < $1.0 }
    }
}
