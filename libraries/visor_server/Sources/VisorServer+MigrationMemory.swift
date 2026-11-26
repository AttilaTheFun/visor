// Claude Code's memory moved with a session: the memory of its
// conversation's project (`~/.claude/projects/<key>/memory`: the MEMORY.md
// index and the files it names), which no conversation file holds, found
// where Claude Code keeps it (ClaudeSessionFiles.memoryFolder: beside the
// transcript, else under the project of the folder's repository or of the
// folder), a link to it followed. A move (and a backup) carries it as a
// packed folder with the id `memory` and no place of its own, so a server
// from before this leaves it be. Here it goes under the project Claude Code
// keeps the memory of the session's new folder under (or, on a restore, its
// folder's), unless that project has a memory already: one is never
// overwritten or merged.

import ClaudeTranscript
import Foundation
import VisorProtocol

extension VisorServer {
    /// The carried memory's id among a move's files.
    static let memoryFileID = "memory"

    /// The memory of a Claude conversation (`conversation`, its file) of a
    /// session in `cwd`, packed into `folder` as a folder named `memory`:
    /// nil when there is none, or none to pack. A memory reached through a
    /// link is packed as the folder it leads to, never as the link (which
    /// the other end refuses: it holds no folder).
    static func packMemory(of conversation: URL, cwd: String, into folder: URL) async -> (file: MigrationFile, url: URL, source: URL)? {
        guard let memory = ClaudeSessionFiles.memoryFolder(conversation: conversation, cwd: cwd, refused: { log("a memory refused: \($0)") })
        else { return nil }
        let archive = folder.appendingPathComponent("memory.tgz", isDirectory: false)
        // tar packs a folder by its own name: one by another name is copied
        // in as `memory` first. Neither follows a link inside it: copyItem
        // copies a link as a link, and tar (`-czf <archive> -C <parent>
        // memory`, no `-h`, `-L`, `-H` or `--dereference`) packs one as
        // one, which the other end refuses if it leads out.
        var packed = memory
        let staged = folder.appendingPathComponent("memory-staged", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        if memory.lastPathComponent != "memory" {
            packed = staged.appendingPathComponent("memory", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: memory, to: packed)
            } catch {
                log("the memory at \(memory.path) could not be copied to pack: \(error.localizedDescription)")
                return nil
            }
        }
        guard await pack(folder: packed, into: archive) == nil else {
            try? FileManager.default.removeItem(at: archive)
            return nil
        }
        return (MigrationFile(id: memoryFileID, place: "", size: fileSize(archive), packed: true), archive, memory)
    }

    /// The memory a move carried, put under the project of `cwd` here
    /// when that project has none, within what is left of the move once
    /// its other files are counted (`landed`: what its packed files
    /// unpacked to, by id). Said in the log either way.
    func putMemory(of move: IncomingMigration, cwd: String, landed: [String: Int]) async {
        guard move.offer.session.agent == .claude,
              let file = move.offer.files.first(where: { $0.id == Self.memoryFileID }) else { return }
        guard let carried = Self.carried(file.id, in: move.folder), Self.fileSize(carried) == file.size else {
            Self.log("the memory of \(move.offer.session.title) was not all carried: left behind")
            return
        }
        let limits = unpackLimits(file, of: move.offer.files, landed: landed, in: Self.memoryProject(cwd))
        _ = await Self.putMemory(carried, of: move.offer.session.title, cwd: cwd, limits: limits)
    }

    /// The folder of Claude's project whose memory a session in `cwd` here
    /// has: its repository's, or its own outside one.
    static func memoryProject(_ cwd: String) -> URL {
        ClaudeSessionFiles.projectsRoot().appendingPathComponent(ClaudeSessionFiles.memoryProjectDirectoryName(for: cwd), isDirectory: true)
    }

    /// The memory packed at `archive` put under the project of `cwd` here
    /// when that project has none, unpacked within `limits`: whether it
    /// was. Said in the log either way.
    static func putMemory(_ archive: URL, of title: String, cwd: String, limits: UnpackLimits) async -> Bool {
        let project = memoryProject(cwd)
        let memory = project.appendingPathComponent("memory", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: memory.path), !names.isEmpty {
            log("the memory of \(title) not put: \(memory.path) has one already")
            return false
        }
        // The folder `memory` alone, in place of an empty one.
        if let problem = await unpack(archive, into: project, only: "memory", limits: limits) {
            log("the memory of \(title) could not be unpacked: \(problem)")
            return false
        }
        return true
    }
}
