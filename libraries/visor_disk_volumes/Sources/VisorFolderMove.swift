// What Visor kept in the home folder moved onto the Visor volume, once, when
// the volume is there (VisorFolders): the data folder, a cache, the logs.
// Run by the process that's about to run the server (or open the cache),
// before anything opens them:
//
// - The data folder's items are moved into `/Volumes/Visor/Data/`, all but
//   `Sessions/`, the working folders of sessions moved in from another
//   computer, which sessions.json and Claude's project keys know by their
//   path: those stay where they are, and go with Migrate… or Move to
//   Container. volumes.json, which Visor Disk Utility writes to the volume
//   once it's there, is dropped if the volume has one already. Any other
//   item the volume already has is put in `Data/moved-aside/`, never lost.
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
        for name in items {
            let from = legacy.appendingPathComponent(name)
            var to = data.appendingPathComponent(name)
            if files.fileExists(atPath: to.path) || isLink(to) {
                if name == VolumesStatus.fileName {
                    try? files.removeItem(at: from)
                    continue
                }
                let aside = data.appendingPathComponent(Self.movedAside, isDirectory: true)
                try? files.createDirectory(at: aside, withIntermediateDirectories: true)
                to = aside.appendingPathComponent(name)
                if files.fileExists(atPath: to.path) { to = aside.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8).lowercased())") }
                log("\(data.path) has \(name) already: the home folder's is kept as \(to.path)")
            }
            do {
                try files.moveItem(at: from, to: to)
                moved.append(name)
            } catch {
                log("\(from.path) couldn't be moved to \(to.path): \(error.localizedDescription)")
            }
        }
        // Emptied but for the sessions' folders: removed when nothing is left.
        try? files.removeItem(at: legacy.appendingPathComponent(".DS_Store"))
        if ((try? files.contentsOfDirectory(atPath: legacy.path)) ?? ["?"]).isEmpty { try? files.removeItem(at: legacy) }
        let left = Self.pending(in: legacy)
        log("the data folder moved to \(data.path): \(moved.joined(separator: ", "))"
            + (left.isEmpty ? "" : "; still at \(legacy.path): \(left.joined(separator: ", "))"))
        return left.isEmpty ? .moved(moved) : .waiting("\(left.joined(separator: ", ")) couldn't be moved")
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
