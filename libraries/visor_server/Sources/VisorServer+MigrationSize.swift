// How much a move carries (Logan, 17 Nov): a cap on each file and on all
// of them, a piece refused past its file's declared size, and a plan
// refused when the files would not fit where they land with room to
// spare. A move carries only the agent's own files for one conversation
// (VisorServer+Migration), so the caps are set by the largest of those:
// a long Claude conversation's transcript runs to hundreds of megabytes,
// and its folder of subagents and long tool results can be as large again.
//
// - migrationFileCap, 2 GiB: several times the longest transcript seen,
//   so no real conversation meets it, while one file can never be more
//   than a bounded share of a disk.
// - migrationTotalCap, 4 GiB: two files at the cap. A move has at most
//   three files (Claude's transcript, its folder, its memory; Codex's
//   rollout alone; OpenRouter's two), so a total of 8 GiB could never be
//   met under a 2 GiB cap on each; 4 GiB is one a transcript and its
//   folder both at their largest would meet.
// - migrationFreeMargin, 1 GiB: what is left free beyond the files where
//   they land, for the agent, the server and the archive's unpacking
//   beside it.
// - unpackEntryCap, 200,000 entries: what one archive (the conversation's
//   folder, the memory) may unpack to in files, folders and links, each an
//   inode whether it holds bytes or none, so that millions of empty ones
//   can't use up a filesystem's fixed count of them. A conversation's
//   folder holds a file or two for each subagent and long tool result, a
//   few thousand at the most.
//
// An archive among them (the conversation's folder, the memory) is held to
// the same caps by what it unpacks to, and to unpackEntryCap, before and
// while it is unpacked (VisorServer+MigrationUnpackSize).

import Foundation
import VisorAgent
import VisorProtocol

extension VisorServer {
    /// The most one file of a move (or a backup) may be.
    nonisolated static let migrationFileCap = 2 << 30
    /// The most a move's files may come to together.
    nonisolated static let migrationTotalCap = 4 << 30
    /// The room left free, beyond a move's files, where they land.
    nonisolated static let migrationFreeMargin = 1 << 30
    /// The most entries (files, folders, links) one archive of a move (or
    /// a backup) may unpack to.
    nonisolated static let unpackEntryCap = 200_000

    /// Why `files` are more than a move carries: nil when they aren't.
    static func oversized(_ files: [MigrationFile]) -> String? {
        for file in files where file.size < 0 || file.size > migrationFileCap {
            return "“\(file.id)” is \(megabytes(file.size)), and a move carries at most \(megabytes(migrationFileCap)) of a file"
        }
        let total = files.reduce(0) { $0 + $1.size }
        guard total <= migrationTotalCap else {
            return "its files come to \(megabytes(total)), and a move carries at most \(megabytes(migrationTotalCap))"
        }
        return nil
    }

    /// Why the session `title`'s own files (`files`, each here at
    /// `sources`) are more than a move, a backup or a session archive
    /// carries, said so that the person can act on it: which file, where it
    /// is, how large, the cap, and what would help. Nil when they fit. (A
    /// transcript has been seen at 2.4 GB, past the 2 GiB cap.)
    static func tooLarge(_ files: [MigrationFile], at sources: [String: URL], title: String) -> String? {
        let start = "“\(title)” is too large to move, back up or export: "
        let help = " A new session's transcript starts small: carry on in one (ask this one for a summary to start it with), and move or export that one instead."
        func named(_ file: MigrationFile) -> String {
            let path = sources[file.id]?.path ?? file.id
            let size = megabytes(file.size) + (file.packed ? " packed" : "")
            if file.id == memoryFileID { return "Claude's memory for its project, \(path), is \(size)" }
            return (file.packed ? "the folder beside its transcript, \(path)," : "its transcript, \(path),") + " is \(size)"
        }
        if let file = files.first(where: { $0.size < 0 || $0.size > migrationFileCap }) {
            return start + named(file) + ", and Visor carries at most \(megabytes(migrationFileCap)) of one file." + help
        }
        let total = files.reduce(0) { $0 + $1.size }
        guard total > migrationTotalCap else { return nil }
        return start + "its files come to \(megabytes(total)) (" + files.map(named).joined(separator: "; ")
            + "), and Visor carries at most \(megabytes(migrationTotalCap)) in all." + help
    }

    /// Why `files` of `agent` would not fit here: where the move keeps them
    /// as they come (migrationsFolder) and under the agent's own folder,
    /// each must have their size and migrationFreeMargin free. Nil when
    /// they fit, or when the system doesn't say how much is free.
    func noRoom(for files: [MigrationFile], agent: AgentKind) -> String? {
        let size = files.reduce(0) { $0 + $1.size }
        var places = [Self.migrationsFolder]
        if let agentFolder = SessionCatalog.agentFolder(agent) { places.append(agentFolder) }
        for place in places {
            guard let free = freeBytes(place) else {
                Self.log("how much is free at \(place.path) is not known: a move there goes on without knowing")
                continue
            }
            if free < size + Self.migrationFreeMargin {
                return "\(place.path) has \(Self.megabytes(free)) free, and the move needs \(Self.megabytes(size)) "
                    + "with \(Self.megabytes(Self.migrationFreeMargin)) to spare"
            }
        }
        return nil
    }

    /// The bytes free on the disk `url` is on (its nearest folder that is
    /// there): nil when the system doesn't say.
    nonisolated static func systemFreeBytes(_ url: URL) -> Int? {
        var path = url.standardizedFileURL.path
        while !FileManager.default.fileExists(atPath: path) {
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return nil }
            path = parent
        }
        return ((try? FileManager.default.attributesOfFileSystem(forPath: path))?[.systemFreeSize] as? NSNumber)?.intValue
    }
}
