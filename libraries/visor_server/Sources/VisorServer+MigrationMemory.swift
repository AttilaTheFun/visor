// Claude Code's memory moved with a session: the memory of the project its
// conversation is kept under (`~/.claude/projects/<key>/memory`: the
// MEMORY.md index and the files it names), which no conversation file
// holds. A move (and a backup) carries it as a packed folder with the id
// `memory` and no place of its own, so a server from before this leaves it
// be. Here it goes under the project of the session's new folder (or, on
// a restore, its folder), unless that project has a memory already: one is
// never overwritten or merged.

import ClaudeTranscript
import Foundation
import VisorProtocol

extension VisorServer {
    /// The carried memory's id among a move's files.
    static let memoryFileID = "memory"

    /// The memory beside a Claude conversation (`conversation`, its file),
    /// packed into `folder`: nil when there is none, or none to pack.
    static func packMemory(beside conversation: URL, into folder: URL) async -> (file: MigrationFile, url: URL)? {
        let memory = conversation.deletingLastPathComponent().appendingPathComponent("memory", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: memory.path), !names.isEmpty else { return nil }
        let archive = folder.appendingPathComponent("memory.tgz", isDirectory: false)
        guard await pack(folder: memory, into: archive) == nil else {
            try? FileManager.default.removeItem(at: archive)
            return nil
        }
        return (MigrationFile(id: memoryFileID, place: "", size: fileSize(archive), packed: true), archive)
    }

    /// The memory a move carried, put under the project of `cwd` here
    /// when that project has none. Said in the log either way.
    func putMemory(of move: IncomingMigration, cwd: String) async {
        guard move.offer.session.agent == .claude,
              let file = move.offer.files.first(where: { $0.id == Self.memoryFileID }) else { return }
        guard let carried = Self.carried(file.id, in: move.folder), Self.fileSize(carried) == file.size else {
            Self.log("the memory of \(move.offer.session.title) was not all carried: left behind")
            return
        }
        _ = await Self.putMemory(carried, of: move.offer.session.title, cwd: cwd)
    }

    /// The memory packed at `archive` put under the project of `cwd` here
    /// when that project has none: whether it was. Said in the log either way.
    static func putMemory(_ archive: URL, of title: String, cwd: String) async -> Bool {
        let project = ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.projectDirectoryName(for: cwd), isDirectory: true)
        let memory = project.appendingPathComponent("memory", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: memory.path), !names.isEmpty {
            log("the memory of \(title) not put: \(memory.path) has one already")
            return false
        }
        // The folder `memory` alone, in place of an empty one.
        if let problem = await unpack(archive, into: project, only: "memory") {
            log("the memory of \(title) could not be unpacked: \(problem)")
            return false
        }
        return true
    }
}
