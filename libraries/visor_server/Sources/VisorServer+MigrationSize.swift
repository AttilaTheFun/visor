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
//
// An archive among them (the conversation's folder, the memory) is held to
// the same caps by what it unpacks to, before and while it is unpacked
// (VisorServer+MigrationUnpackSize).

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
