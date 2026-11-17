// How much an archive a move (or a restore) carries may unpack to: the
// conversation's folder and Claude's memory come packed, and a small
// archive can say it holds, or hold, far more than it is (a file of zeros
// compresses a thousandfold, and a million empty files or folders take a
// million inodes and no bytes). Held to the caps of
// VisorServer+MigrationSize twice over:
//
// - before: its listing (`tar -tv`) is read for each entry's size, and
//   their sum is refused past a file's cap (migrationFileCap), past what is
//   left of the move's total (migrationTotalCap, less its other files: each
//   as carried, or as it unpacked to once it has), or past the room where
//   it unpacks less migrationFreeMargin. A hard link or a sparse file counts
//   at the size it declares, never less. Its entries (`tar -t`'s lines, and
//   the folders their names lie in, listed or not) are refused past
//   unpackEntryCap.
// - during: what the listing says is the archive's word, so the unpacking
//   itself is measured every 200 ms (each file once, however many names it
//   has; every entry counted) and tar killed when it runs past the sum or
//   the count declared (and a little slack) or a cap; once more when it is
//   done. Its folder is removed either way
//   (VisorServer+MigrationContainment).
//
// The listing is asked for with `--numeric-owner`, so that an owner's name
// (the archive's to say, and free to hold spaces) never stands where the
// size is read: GNU tar lists `-rw-r--r-- 501/20 1234 2026-11-16 10:00 name`
// and bsdtar (the Mac's, Windows's) `-rw-r--r--  0 501 20 1234 Nov 16 10:00
// name`. Both print a name's control characters escaped, a line an entry.

import Foundation
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// What one archive may unpack to.
    struct UnpackLimits: Sendable {
        /// The most it may come to: it is one of the move's files.
        var fileCap = VisorServer.migrationFileCap
        /// What is left of the move's total once its other files are counted.
        var budget = VisorServer.migrationTotalCap
        /// The bytes free where it unpacks: nil when the system doesn't say.
        var free: Int?
        /// What must stay free there beyond it.
        var margin = VisorServer.migrationFreeMargin
        /// How far past what its listing declared it may run before it is
        /// stopped.
        var slack = 1 << 20
        /// The most entries (files, folders, links) it may make.
        var entries = VisorServer.unpackEntryCap
        /// How many more entries than its listing declared it may make
        /// before it is stopped.
        var entrySlack = 16
        /// How often it is measured while it unpacks.
        var every: Duration = .milliseconds(200)
    }

    /// What `file` of `files` (a move's, or a backup's) may unpack to in
    /// `folder`: within a file's cap, what is left of the total once the
    /// other files are counted (each as carried, or as it unpacked to:
    /// `landed`, by id), and the room there.
    func unpackLimits(_ file: MigrationFile, of files: [MigrationFile], landed: [String: Int], in folder: URL) -> UnpackLimits {
        let others = files.filter { $0.id != file.id }.reduce(0) { $0 + (landed[$1.id] ?? max(0, $1.size)) }
        return UnpackLimits(budget: Self.migrationTotalCap - others, free: freeBytes(folder))
    }

    /// The sizes a `tar -tv --numeric-owner` listing declares, added up, and
    /// how many entries it lists: GNU tar's lines or bsdtar's. A device
    /// counts nothing (it holds no bytes, and is refused once unpacked). Nil
    /// when a line is neither, or the sum is past counting.
    nonisolated static func listedBytes(_ listing: String) -> (entries: Int, bytes: Int)? {
        var entries = 0, bytes = 0
        for line in listing.split(separator: "\n") where !line.isEmpty {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let kind = fields[0].first else { return nil }
            // GNU: mode, uid/gid, size. bsdtar: mode, links, uid, gid, size.
            let gnu = fields[1].contains("/")
            guard gnu || (fields[1].allSatisfy(\.isNumber) && fields[2].allSatisfy(\.isNumber) && fields[3].allSatisfy(\.isNumber)) else {
                return nil
            }
            let field = gnu ? fields[2] : fields[4]
            let size: Int
            if kind == "c" || kind == "b" {
                size = 0
            } else {
                guard let declared = Int(field), declared >= 0 else { return nil }
                size = declared
            }
            let (sum, overflow) = bytes.addingReportingOverflow(size)
            guard !overflow else { return nil }
            bytes = sum
            entries += 1
        }
        return (entries, bytes)
    }

    /// How many entries unpacking an archive makes, by its `tar -t` names:
    /// each path named, and each folder a name lies in whether it is listed
    /// or not (`a/b/c` alone makes `a` and `a/b` too), counted once; or how
    /// many names there are, when that is more (one listed twice). Counted
    /// no further than past `most`.
    nonisolated static func listedEntries(_ names: [Substring], most: Int) -> Int {
        guard names.count <= most else { return names.count }
        // The paths as a tree of their parts (a name's parts are never
        // copied, however deep it goes): every node but the root an entry.
        var children: [[Substring: Int]] = [[:]]
        for name in names {
            var node = 0
            for part in name.split(separator: "/") where part != "." {
                if let child = children[node][part] {
                    node = child
                    continue
                }
                children.append([:])
                children[node][part] = children.count - 1
                node = children.count - 1
                if children.count - 1 > most { return children.count - 1 }
            }
        }
        return max(names.count, children.count - 1)
    }

    /// Why an archive that makes `entries` can't be unpacked within
    /// `limits`: nil when it can.
    static func entryRefusal(_ entries: Int, _ limits: UnpackLimits) -> String? {
        guard entries > limits.entries else { return nil }
        return "it holds \(entries) entries (files, folders and links), and an archive may hold at most \(limits.entries)"
    }

    /// Why an archive that declares `bytes` can't be unpacked in `folder`
    /// within `limits`: which limit it is past. Nil when it can.
    static func unpackRefusal(_ bytes: Int, _ limits: UnpackLimits, in folder: URL) -> String? {
        if bytes > limits.fileCap {
            return "it unpacks to \(megabytes(bytes)), and a move carries at most \(megabytes(limits.fileCap)) of a file"
        }
        if bytes > limits.budget {
            return "it unpacks to \(megabytes(bytes)), and of the \(megabytes(migrationTotalCap)) a move carries in all, "
                + "\(limits.budget > 0 ? megabytes(limits.budget) : "nothing") is left once its other files are counted"
        }
        if let free = limits.free, bytes > free - limits.margin {
            return "it unpacks to \(megabytes(bytes)), and \(folder.path) has \(megabytes(free)) free, "
                + "which must keep \(megabytes(limits.margin)) to spare"
        }
        return nil
    }

    /// The most an archive that declares `declared` may come to while it
    /// unpacks in `folder` before it is stopped, and why it is stopped
    /// there: the least of what it declared (and the slack) and the limits.
    static func unpackBound(_ declared: Int, _ limits: UnpackLimits, in folder: URL) -> (bytes: Int, why: String) {
        var bound = (declared.addingReportingOverflow(limits.slack).overflow ? Int.max : declared + limits.slack,
                     "it unpacked to more than the \(megabytes(declared)) its listing declared")
        if limits.fileCap < bound.0 { bound = (limits.fileCap, "it unpacked to more than the \(megabytes(limits.fileCap)) a move carries of a file") }
        if limits.budget < bound.0 {
            bound = (limits.budget, "it unpacked to more than the \(megabytes(limits.budget)) left of what a move carries in all")
        }
        if let free = limits.free, free - limits.margin < bound.0 {
            bound = (free - limits.margin, "it unpacked to more than \(folder.path) has free with \(megabytes(limits.margin)) to spare")
        }
        return bound
    }

    /// The most entries an archive whose listing declares `declared` may
    /// make while it unpacks before it is stopped, and why it is stopped
    /// there: the less of what it declared (and the slack) and the cap.
    static func entryBound(_ declared: Int, _ limits: UnpackLimits) -> (entries: Int, why: String) {
        let past = declared.addingReportingOverflow(limits.entrySlack)
        if limits.entries < (past.overflow ? Int.max : past.partialValue) {
            return (limits.entries, "it unpacked to more than the \(limits.entries) entries an archive may hold")
        }
        return (past.partialValue, "it unpacked to more than the \(declared) entries its listing declared")
    }

    /// The bytes of the files under `root`, each counted once however many
    /// names it has; links and folders count nothing, and a folder that
    /// can't be looked in is passed by (the walk after the unpacking, which
    /// opens each, refuses one).
    nonisolated static func unpackedBytes(_ root: URL) -> Int {
        unpacked(root).bytes
    }

    /// What is under `root`: how many entries (files, folders, links,
    /// anything) and the bytes of its files, as unpackedBytes counts them.
    /// Measured while tar writes, off the main actor.
    nonisolated static func unpacked(_ root: URL) -> (entries: Int, bytes: Int) {
        let files = FileManager.default
        var seen: Set<NSNumber> = []
        var total = 0, entries = 0
        var folders = [root.path]
        while let folder = folders.popLast() {
            for item in (try? files.contentsOfDirectory(atPath: folder)) ?? [] {
                entries += 1
                let path = folder + "/" + item
                guard let attributes = try? files.attributesOfItem(atPath: path), let type = attributes[.type] as? FileAttributeType else { continue }
                if type == .typeDirectory {
                    folders.append(path)
                    continue
                }
                guard type == .typeRegular else { continue }
                if let count = (attributes[.referenceCount] as? NSNumber)?.intValue, count > 1,
                   let node = attributes[.systemFileNumber] as? NSNumber, !seen.insert(node).inserted { continue }
                total += (attributes[.size] as? NSNumber)?.intValue ?? 0
            }
        }
        return (entries, total)
    }

    /// The archive unpacked by `tar` into `staging`, measured as it goes
    /// and stopped past `bound` (unpackBound) or `entries` (entryBound):
    /// what went wrong, if anything.
    static func extract(_ archive: URL, into staging: URL, tar: String, bound: (bytes: Int, why: String),
                        entries: (entries: Int, why: String), every interval: Duration) async -> String? {
        let limit = bound.bytes, most = entries.entries
        guard let result = await Command.output(tar, ["--no-same-owner", "--no-same-permissions", "-xzf", archive.path, "-C", staging.path],
                                                errors: true, every: interval, stopping: {
                                                    let now = unpacked(staging)
                                                    return now.bytes > limit || now.entries > most
                                                }) else {
            return "tar could not be started"
        }
        // Which it ran past: what is there only grows, so measured again.
        if result.stopped { return (unpacked(staging).entries > most ? entries.why : bound.why) + ", and was stopped" }
        guard result.status == 0 else { return result.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }
}
