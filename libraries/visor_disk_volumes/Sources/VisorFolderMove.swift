// What Visor kept in the home folder moved onto the Visor volume, once, when
// the volume is there (VisorFolders): the data folder, a cache, the logs.
// Run by the process that's about to run the server (or open the cache),
// before anything opens them:
//
// - The data folder's items are moved into `/Volumes/Visor/Data/`, all but
//   `Sessions/`, the working folders of sessions moved in from another
//   computer, which the sessions' store and Claude's project keys know by
//   their path: those stay where they are, and go with Migrate… or Move to
//   Container. volumes.json, which Visor Disk Utility writes to the volume
//   once it's there, is dropped if the volume has one already. Any other
//   item the volume already has is put in `Data/moved-aside/`, never lost;
//   a database (server.sqlite, the sessions' store) with its own files
//   beside it (`-wal`, `-shm`, `-journal`), which go where it goes, so a
//   database is never put beside another's log. A database's files move
//   together, by staged names first (`.moving`), and all go back if one
//   can't; what a crash in the middle left staged is sorted out at the
//   next start on the volume, and never deleted: one whose place is taken
//   is kept in `moved-aside/` as `<name>.staged-<time>`.
// - Not while an agent's host still answers in its `hosts/` folder: an
//   in-place relaunch leaves the agents running, and their hosts' sockets
//   and token files are in that folder. The move waits for a start with no
//   agent running (a restart of the Mac, or Quit Visor), and the data folder
//   stays in the home folder until then (`dataFolder`).
// - A cache's folder is moved whole if the volume has none yet, else
//   dropped (it's a cache).
// - A log is moved, or added to the end of the one on the volume.
//
// Foundation alone: tested on Linux with scratch folders.

import Foundation

public struct VisorFolderMove: Sendable {
    public var folders: VisorFolders
    /// Whether an agent's host answers at a socket file's path (POSIX's
    /// connect; tests give their own).
    public var answers: @Sendable (String) -> Bool
    public var log: @Sendable (String) -> Void

    public init(folders: VisorFolders, answers: @escaping @Sendable (String) -> Bool, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.folders = folders
        self.answers = answers
        self.log = log
    }

    /// The data folder's items that stay in the home folder: the working
    /// folders of sessions moved in, which are known by their paths.
    public static let staying: Set<String> = ["Sessions", ".DS_Store"]
    /// Where an item the volume already had is put, in its data folder.
    public static let movedAside = "moved-aside"
    /// The files SQLite keeps beside a database, by the end of their names.
    public static let databaseCompanions = ["-wal", "-shm", "-journal"]

    /// The item a name goes with: a database's, for one of its companions;
    /// else itself.
    static func unit(of name: String) -> String {
        databaseCompanions.first { name.hasSuffix($0) && name.count > $0.count }.map { String(name.dropLast($0.count)) } ?? name
    }

    /// What the data move did.
    public enum Outcome: Equatable, Sendable {
        /// Nothing to move: no volume, or nothing left in the home folder.
        case nothing
        /// These items moved onto the volume.
        case moved([String])
        /// Not now (`why`): the data folder stays in the home folder.
        case waiting(String)
    }

    /// The data folder to use: the volume's once nothing is left to move
    /// there from the home folder, or once its settings are there (a move
    /// that left something behind: what's left is tried again at the next
    /// start); else the home folder's, as before. Never a home folder the
    /// settings have left: a server started on one makes new settings, a
    /// new server id and no sessions (the Mini's window, 24 Nov).
    public static func dataFolder(_ folders: VisorFolders) -> URL {
        guard folders.onVolume else { return folders.legacyData }
        if FileManager.default.fileExists(atPath: folders.data.appendingPathComponent(settingsName).path) { return folders.data }
        return pending(in: folders.legacyData).isEmpty ? folders.data : folders.legacyData
    }

    /// The server's settings file, which says whose data folder it is.
    static let settingsName = "settings.json"

    /// The items of the home folder's data folder still to move.
    public static func pending(in legacy: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: legacy.path)) ?? []
        return names.filter { !staying.contains($0) }.sorted()
    }

    /// The data folder moved onto the volume, unless an agent's host still
    /// answers in it.
    @discardableResult
    public func moveData() -> Outcome {
        guard folders.onVolume else { return .nothing }
        let legacy = folders.legacyData
        finishStaged(from: legacy)
        let items = Self.pending(in: legacy)
        guard !items.isEmpty else { return .nothing }
        if let host = answeringHost(in: legacy.appendingPathComponent("hosts", isDirectory: true)) {
            let why = "an agent's host still answers at \(host): its agents were left running"
            log("the data folder stays at \(legacy.path) for now (\(why)); it moves to \(folders.data.path) at a start with none running")
            return .waiting(why)
        }
        // No host answers at any of them: their socket files are dead, and
        // a socket can't be copied to another volume (Foundation's move
        // there is a copy), which left `hosts/` behind on the Mini.
        removeDeadSockets(in: legacy.appendingPathComponent("hosts", isDirectory: true))
        let files = FileManager.default
        let data = folders.data
        var moved: [String] = []
        do {
            try files.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            log("the data folder couldn't be made at \(data.path): \(error.localizedDescription); it stays at \(legacy.path)")
            return .waiting("\(data.path) couldn't be made")
        }
        // Whether the volume has an item already, a database's companions
        // with it, told before any moves; and the name each kept aside goes
        // by there, the same for all of a database's files.
        let aside = data.appendingPathComponent(Self.movedAside, isDirectory: true)
        let together = { (unit: String) in [unit] + Self.databaseCompanions.map { unit + $0 } }
        let taken = Set(items.map(Self.unit(of:)).filter { unit in
            together(unit).contains { files.fileExists(atPath: data.appendingPathComponent($0).path) || isLink(data.appendingPathComponent($0)) }
        })
        var asideTags: [String: String] = [:]
        var steps: [Step] = []
        for name in items {
            let from = legacy.appendingPathComponent(name)
            var to = data.appendingPathComponent(name)
            let unit = Self.unit(of: name)
            if taken.contains(unit) {
                if name == VolumesStatus.fileName {
                    try? files.removeItem(at: from)
                    continue
                }
                try? files.createDirectory(at: aside, withIntermediateDirectories: true)
                let tag = asideTags[unit] ?? (together(unit).contains { files.fileExists(atPath: aside.appendingPathComponent($0).path) }
                    ? "-\(UUID().uuidString.prefix(8).lowercased())" : "")
                asideTags[unit] = tag
                to = aside.appendingPathComponent(unit + tag + name.dropFirst(unit.count))
                log("\(data.path) has \(unit) already: the home folder's \(name) is kept as \(to.path)")
            }
            steps.append(Step(unit: unit, name: name, from: from, to: to))
        }
        var units: [String] = []
        for step in steps where !units.contains(step.unit) { units.append(step.unit) }
        for unit in units {
            let group = steps.filter { $0.unit == unit }
            if let failure = move(together: group) { log(failure) } else { moved += group.map(\.name) }
        }
        // Emptied but for the sessions' folders: removed when nothing is left.
        try? files.removeItem(at: legacy.appendingPathComponent(".DS_Store"))
        if ((try? files.contentsOfDirectory(atPath: legacy.path)) ?? ["?"]).isEmpty { try? files.removeItem(at: legacy) }
        let left = Self.pending(in: legacy)
        log("the data folder moved to \(data.path): \(moved.joined(separator: ", "))"
            + (left.isEmpty ? "" : "; still at \(legacy.path): \(left.joined(separator: ", "))"))
        return left.isEmpty ? .moved(moved) : .waiting("\(left.joined(separator: ", ")) couldn't be moved")
    }

    /// One item's move: its name, the unit it goes with (a database's, for
    /// one of its files), from where to where.
    private struct Step {
        var unit: String
        var name: String
        var from: URL
        var to: URL
    }

    /// The end of a staged name: a database's file on its way.
    static let staging = ".moving"

    /// The volume's name for a file still on its way to `url`.
    private static func staged(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + staging)
    }

    /// A unit moved whole: an item on its own as it is; a database (a
    /// `.sqlite` file, or one with its files beside it) each of its files to
    /// a staged name beside where it goes, then all of them into place, and
    /// on a failure every one put back, so a database is never split from
    /// its log. Why not, when it didn't move.
    private func move(together group: [Step]) -> String? {
        let files = FileManager.default
        guard let first = group.first else { return nil }
        guard group.count > 1 || first.name.hasSuffix(".sqlite") else {
            do {
                try files.moveItem(at: first.from, to: first.to)
                return nil
            } catch {
                return "\(first.from.path) couldn't be moved to \(first.to.path): \(error.localizedDescription)"
            }
        }
        var staged: [Step] = []
        var placed: [Step] = []
        var failure: String?
        for step in group {
            if files.fileExists(atPath: Self.staged(step.to).path) {
                keepAside(Self.staged(step.to), why: "found where \(step.name) is staged")
            }
            do {
                try files.moveItem(at: step.from, to: Self.staged(step.to))
                staged.append(step)
            } catch {
                failure = "\(step.from.path) couldn't be moved to \(step.to.path): \(error.localizedDescription)"
                break
            }
        }
        if failure == nil {
            for step in group {
                do {
                    try files.moveItem(at: Self.staged(step.to), to: step.to)
                    placed.append(step)
                } catch {
                    failure = "\(step.name) couldn't be put at \(step.to.path): \(error.localizedDescription)"
                    break
                }
            }
        }
        guard let failure else { return nil }
        for step in staged {
            let at = placed.contains { $0.name == step.name } ? step.to : Self.staged(step.to)
            do {
                try files.moveItem(at: at, to: step.from)
            } catch {
                // Left where it is (staged, the next start sorts it out), never lost.
                log("\(at.path) couldn't be put back at \(step.from.path): \(error.localizedDescription); it is left where it is")
            }
        }
        return failure + "; \(first.unit) and its files stay at \(first.from.deletingLastPathComponent().path)"
    }

    /// What a move cut short left staged (a crash in a copy to the volume):
    /// put back in the home folder while another file of its unit is still
    /// there, else put where it was going. Never deleted: one whose place is
    /// taken (the home folder has the file again, a later start without the
    /// volume having made it there, or a copy cut short) is kept aside
    /// (`keepAside`). In moved-aside/ a file's name carries its tag after its
    /// unit's (`-<8 hex>`), which the home folder's hasn't.
    private func finishStaged(from legacy: URL) {
        let files = FileManager.default
        let aside = folders.data.appendingPathComponent(Self.movedAside, isDirectory: true)
        for folder in [folders.data, aside] {
            for name in ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where name.hasSuffix(Self.staging) {
                let stage = folder.appendingPathComponent(name)
                let base = String(name.dropLast(Self.staging.count))
                let homeName = folder == aside ? Self.untagged(base) : base
                let unit = Self.unit(of: homeName)
                let home = legacy.appendingPathComponent(homeName)
                let unitAtHome = ([unit] + Self.databaseCompanions.map { unit + $0 }).contains {
                    files.fileExists(atPath: legacy.appendingPathComponent($0).path)
                }
                if files.fileExists(atPath: home.path) {
                    keepAside(stage, why: "the home folder has \(homeName) too")
                } else if unitAtHome {
                    do {
                        try files.moveItem(at: stage, to: home)
                        log("\(stage.path), left by a move cut short, is back at \(home.path), with the rest of \(unit)")
                    } catch {
                        log("\(stage.path), left by a move cut short, couldn't be put back at \(home.path): \(error.localizedDescription); it is left where it is")
                    }
                } else if !files.fileExists(atPath: folder.appendingPathComponent(base).path) {
                    do {
                        try files.moveItem(at: stage, to: folder.appendingPathComponent(base))
                        log("\(stage.path), left by a move cut short, is put in its place")
                    } catch {
                        log("\(stage.path), left by a move cut short, couldn't be put in its place: \(error.localizedDescription); it is left where it is")
                    }
                } else {
                    keepAside(stage, why: "\(base) is there already")
                }
            }
        }
    }

    /// A staged file kept, never deleted: in moved-aside/ as
    /// `<unit>.staged-<yyyymmdd-hhmmss><its end>` (`-wal` and the like after
    /// it, so a database and its log kept so still go together), never over
    /// another, and logged.
    private func keepAside(_ stage: URL, why: String) {
        let files = FileManager.default
        let aside = folders.data.appendingPathComponent(Self.movedAside, isDirectory: true)
        try? files.createDirectory(at: aside, withIntermediateDirectories: true)
        let base = String(stage.lastPathComponent.dropLast(Self.staging.count))
        let unit = Self.unit(of: base)
        let end = String(base.dropFirst(unit.count))
        let stamp = Self.stamp(Date())
        var to = aside.appendingPathComponent("\(unit).staged-\(stamp)\(end)")
        var number = 1
        while files.fileExists(atPath: to.path) || isLink(to) {
            number += 1
            to = aside.appendingPathComponent("\(unit).staged-\(stamp)-\(number)\(end)")
        }
        do {
            try files.moveItem(at: stage, to: to)
            log("\(stage.path), left by a move cut short (\(why)), is kept as \(to.path)")
        } catch {
            log("\(stage.path), left by a move cut short (\(why)), couldn't be kept aside: \(error.localizedDescription); it is left where it is")
        }
    }

    /// A name in moved-aside/ without the tag its unit was given there
    /// (`server.sqlite-1a2b3c4d-wal` is `server.sqlite-wal`); one with none,
    /// itself.
    public static func untagged(_ name: String) -> String {
        let end = databaseCompanions.first { name.hasSuffix($0) } ?? ""
        let core = name.dropLast(end.count)
        let tag = core.suffix(9)
        guard core.count > 9, tag.first == "-", tag.dropFirst().allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return name }
        return String(core.dropLast(9)) + end
    }

    /// A moment as a kept file is named by it: 20261127-153000 (UTC).
    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: date)
    }

    /// A cache's folder (`Server`, `Client`) moved onto the volume whole,
    /// or dropped if the volume has one. Whether it moved.
    @discardableResult
    public func moveCaches(_ part: String, bundleID: String) -> Bool {
        guard folders.onVolume else { return false }
        let files = FileManager.default
        let from = folders.legacyCaches(part, bundleID: bundleID)
        guard files.fileExists(atPath: from.path) else { return false }
        let to = folders.caches(part, bundleID: bundleID)
        var moved = false
        if files.fileExists(atPath: to.path) {
            try? files.removeItem(at: from)
        } else {
            try? files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            moved = (try? files.moveItem(at: from, to: to)) != nil
            if !moved { try? files.removeItem(at: from) }
        }
        let bundle = from.deletingLastPathComponent()
        if ((try? files.contentsOfDirectory(atPath: bundle.path)) ?? ["?"]).isEmpty { try? files.removeItem(at: bundle) }
        log("the \(part.lowercased()) cache \(moved ? "moved to \(to.path)" : "at \(from.path) dropped: the volume has its own")")
        return moved
    }

    /// Visor's logs (`names`) moved from ~/Library/Logs onto the volume, or
    /// added to the end of the one there. The names moved.
    @discardableResult
    public func moveLogs(_ names: [String] = VisorFolders.logNames) -> [String] {
        guard folders.onVolume else { return [] }
        let files = FileManager.default
        try? files.createDirectory(at: folders.logs, withIntermediateDirectories: true)
        var moved: [String] = []
        for name in names {
            let from = folders.legacyLogs.appendingPathComponent(name)
            guard files.fileExists(atPath: from.path) else { continue }
            let to = folders.logs.appendingPathComponent(name)
            if files.fileExists(atPath: to.path), let handle = try? FileHandle(forWritingTo: to), let old = try? Data(contentsOf: from) {
                let added = (try? handle.seekToEnd()).flatMap { _ in try? handle.write(contentsOf: old) } != nil
                try? handle.close()
                if added {
                    try? files.removeItem(at: from)
                    moved.append(name)
                }
            } else if (try? files.moveItem(at: from, to: to)) != nil {
                moved.append(name)
            }
        }
        if !moved.isEmpty { log("logs moved to \(folders.logs.path): \(moved.joined(separator: ", "))") }
        return moved
    }

    /// The first agent host's socket that still answers in `hosts`.
    private func answeringHost(in hosts: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: hosts.path)) ?? []
        return names.sorted().lazy.map { hosts.appendingPathComponent($0).path }.first { $0.hasSuffix(".sock") && answers($0) }
    }

    /// The socket files of hosts that no longer answer, removed.
    private func removeDeadSockets(in hosts: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: hosts.path)) ?? []
        let dead = names.filter { $0.hasSuffix(".sock") }
        for name in dead { try? FileManager.default.removeItem(at: hosts.appendingPathComponent(name)) }
        if !dead.isEmpty { log("\(dead.count) socket files of hosts that no longer answer removed from \(hosts.path)") }
    }

    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
