// Sessions backed up to a folder on this computer and restored from one
// (`/api/backups`; docs/protocol.md): each half of a move to another server
// (VisorServer+Migration.swift), with a folder in the middle, to keep
// sessions through an update that might lose them. A backup writes, for
// each session, what a move would carry — the agent's own files for its
// conversation (to its last whole line), and, asked for, the projects a
// move would copy rather than clone — beside the session as a move offers
// it. A restore puts back what is missing here and leaves what is here: a
// conversation file at least as long as the one kept stays (a shorter one
// is set aside, never removed), a session still here is left as it is, and
// one that is gone is started again under its own id on the same
// conversation.
//
//     <folder>/backup.json             what it holds (SessionBackup)
//     <folder>/<session>/offer.json    the session, as a move offers it
//     <folder>/<session>/<file>        its files (backupName)

import Foundation
import VisorProtocol

extension VisorServer {
    /// Where backups go unless the request names a folder: beside the
    /// sessions' store, one folder each, by when it was made.
    static var backupsFolder: URL { storeURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true) }

    func routeBackups(_ request: HTTPRequest, parts: [String], respond: @escaping (HTTPResponse) -> Void) {
        let body = Envelope.decodeBody(request.body)
        Task {
            let reply: Envelope
            switch (request.method, parts.count) {
            case ("GET", 1):
                var listed = Envelope(type: "backups")
                listed.backups = Self.keptBackups()
                reply = listed
            case ("POST", 1):
                let folder = body.path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                reply = await backUp(body.sessionIDs, projects: body.projects ?? false, to: folder)
            case ("POST", 2) where parts[1] == "restore":
                guard let path = body.path, !path.isEmpty else { return respond(HTTPResponse(400, Envelope.error("Which backup (path)?").encoded())) }
                reply = await restore(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true), only: body.sessionIDs)
            default:
                return respond(HTTPResponse(404, "{\"error\":\"not found\"}"))
            }
            respond(reply.type == "error" ? HTTPResponse(400, reply.encoded()) : .json(reply.encoded()))
        }
    }

    // MARK: Backing up

    /// Backs up the sessions named (every one not archived, when none) to
    /// `folder` (a new one under backupsFolder, when none): the backup, with
    /// what became of each.
    func backUp(_ ids: [String]?, projects: Bool, to chosen: URL?) async -> Envelope {
        let now = Date()
        let folder = chosen ?? Self.backupsFolder.appendingPathComponent(Self.backupStamp(now), isDirectory: true)
        let files = FileManager.default
        if let inside = try? files.contentsOfDirectory(atPath: folder.path), !inside.isEmpty {
            return .error("\(folder.path) is not empty: a backup goes into a folder of its own.")
        }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .error("Could not make \(folder.path): \(error.localizedDescription)")
        }
        let chosenRecords = ids.map { wanted in sessions.filter { wanted.contains($0.info.id) } } ?? sessions.filter { !$0.info.archived }
        var items: [SessionBackupItem] = []
        for record in chosenRecords {
            items.append(await backUp(record, projects: projects, into: folder.appendingPathComponent(record.info.id, isDirectory: true)))
        }
        let backup = SessionBackup(path: folder.path, created: now.timeIntervalSince1970, from: hostName, sessions: items,
                                   size: Self.folderSize(folder))
        do {
            try Self.write(backup.json, to: folder.appendingPathComponent("backup.json", isDirectory: false))
        } catch {
            return .error("Could not write \(folder.path)/backup.json: \(error.localizedDescription)")
        }
        Self.log("backed up \(items.filter(\.kept).count) of \(items.count) sessions to \(folder.path)")
        var e = Envelope(type: "backup")
        e.backup = backup
        return e
    }

    /// One session into its own folder of the backup: its offer and its
    /// files (and the projects a move would copy, when asked).
    private func backUp(_ record: SessionRecord, projects: Bool, into folder: URL) async -> SessionBackupItem {
        let item = { (outcome: String, kept: Bool) in SessionBackupItem(id: record.info.id, title: record.info.title, outcome: outcome, kept: kept) }
        guard let resume = record.process.resumeID, !resume.isEmpty else { return item("Not backed up: it has no conversation yet.", false) }
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        var carried: (offer: MigrationOffer, urls: [String: URL])
        switch await offer(of: record, resume: resume, token: "backup", packingInto: folder) {
        case .success(let made): carried = made
        case .failure(let failure):
            try? files.removeItem(at: folder)
            return item("Not backed up: \(failure.message)", false)
        }
        for file in carried.offer.files {
            guard let url = carried.urls[file.id] else { continue }
            let kept = folder.appendingPathComponent(Self.backupName(of: file), isDirectory: false)
            // A folder was packed in place; a file is copied to its last
            // whole line, as a move reads it.
            if file.packed {
                if url != kept { try? files.moveItem(at: url, to: kept) }
            } else if let problem = Self.copy(url, bytes: file.size, to: kept) {
                try? files.removeItem(at: folder)
                return item("Not backed up: \(problem)", false)
            }
        }
        // The projects a move would copy rather than clone, when asked:
        // packed as a move packs them (what git tracks, and its .git).
        var missed: [String] = []
        if projects {
            for (index, project) in carried.offer.projects.enumerated() where project.isRepository && (project.remote == nil || project.unshared) {
                let file = MigrationFile(id: "project-\(index)", place: "", size: 0, packed: true)
                let archive = folder.appendingPathComponent(Self.backupName(of: file), isDirectory: false)
                if await ProjectSurvey.pack(project.path, into: archive) != nil {
                    try? files.removeItem(at: archive)
                    missed.append(project.path)
                    continue
                }
                carried.offer.files.append(MigrationFile(id: file.id, place: "", size: Self.fileSize(archive), packed: true))
            }
        }
        do {
            try Self.write(carried.offer.json, to: folder.appendingPathComponent("offer.json", isDirectory: false))
        } catch {
            try? files.removeItem(at: folder)
            return item("Not backed up: \(error.localizedDescription)", false)
        }
        return item(missed.isEmpty ? "Backed up." : "Backed up, but not \(missed.joined(separator: ", ")): it could not be packed.", true)
    }

    /// The backups kept in backupsFolder, newest first.
    static func keptBackups() -> [SessionBackup] {
        let files = FileManager.default
        // By name under backupsFolder, as a backup made there says its
        // path (a listing's URLs resolve links: /private/var for /var).
        let names = (try? files.contentsOfDirectory(atPath: backupsFolder.path)) ?? []
        return names.map { backupsFolder.appendingPathComponent($0, isDirectory: true) }.compactMap { folder in
            guard let data = files.contents(atPath: folder.appendingPathComponent("backup.json").path),
                  let backup = SessionBackup(json: parseJSON(String(decoding: data, as: UTF8.self)) ?? .null) else { return nil }
            // Found where it is now, whatever path it was made at.
            var found = backup
            found.path = folder.path
            return found
        }
        .sorted { $0.created > $1.created }
    }

    // MARK: Restoring

    /// Puts back the sessions of the backup at `folder` (those named, or
    /// all): what became of each.
    func restore(from folder: URL, only ids: [String]?) async -> Envelope {
        let files = FileManager.default
        guard let data = files.contents(atPath: folder.appendingPathComponent("backup.json").path),
              var backup = SessionBackup(json: parseJSON(String(decoding: data, as: UTF8.self)) ?? .null) else {
            return .error("\(folder.path) holds no backup.")
        }
        backup.path = folder.path
        var items: [SessionBackupItem] = []
        for item in backup.sessions where item.kept && (ids?.contains(item.id) ?? true) {
            items.append(await restore(item, from: folder.appendingPathComponent(item.id, isDirectory: true), made: backup.created))
        }
        backup.sessions = items
        Self.log("restored from \(folder.path): " + items.map { "\($0.title) (\($0.id)): \($0.outcome)" }.joined(separator: "; "))
        var e = Envelope(type: "backup")
        e.backup = backup
        e.sessions = sessions.map(\.info)
        return e
    }

    /// One session put back: its conversation's files where missing or
    /// shorter, its projects where missing, and the session itself when it
    /// is gone.
    private func restore(_ item: SessionBackupItem, from folder: URL, made: Double) async -> SessionBackupItem {
        var result = item
        let files = FileManager.default
        guard let data = files.contents(atPath: folder.appendingPathComponent("offer.json").path),
              let offer = MigrationOffer(json: parseJSON(String(decoding: data, as: UTF8.self)) ?? .null) else {
            result.outcome = "Not restored: its files are not in the backup."
            return result
        }
        let home = SessionCatalog.home.path
        let cwd = Self.path(offer.session.cwd, from: offer.home, to: home)
        var put: [String] = []
        // Its projects first: the session's own folder must be there before
        // its agent starts in it.
        for (index, project) in offer.projects.enumerated() {
            let path = Self.path(project.path, from: offer.home, to: home)
            guard !files.fileExists(atPath: path) else { continue }
            if let file = offer.files.first(where: { $0.id == "project-\(index)" }) {
                try? files.createDirectory(atPath: path, withIntermediateDirectories: true)
                if let problem = await Self.unpack(folder.appendingPathComponent(Self.backupName(of: file)), into: URL(fileURLWithPath: path)) {
                    result.outcome = "Not restored: could not unpack \(path): \(problem)"
                    return result
                }
                put.append(path)
            } else if index == 0 {
                try? files.createDirectory(atPath: path, withIntermediateDirectories: true)
                put.append(path + " (made empty)")
            }
        }
        for file in offer.files where !file.place.isEmpty {
            let kept = folder.appendingPathComponent(Self.backupName(of: file), isDirectory: false)
            guard let destination = SessionCatalog.destination(of: file.place, agent: offer.session.agent, cwd: cwd) else {
                result.outcome = "Not restored: nowhere to put \(file.place)."
                return result
            }
            try? files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.packed {
                // A folder (subagents' records): put back only when gone.
                guard !files.fileExists(atPath: destination.path) else { continue }
                if let problem = await Self.unpack(kept, into: destination.deletingLastPathComponent()) {
                    result.outcome = "Not restored: could not unpack \(file.place): \(problem)"
                    return result
                }
                put.append(destination.lastPathComponent)
                continue
            }
            // A conversation here at least as long as the one kept has
            // gone on since: it stays. A shorter one is set aside.
            if files.fileExists(atPath: destination.path) {
                if Self.fileSize(destination) >= file.size { continue }
                let aside = destination.deletingLastPathComponent()
                    .appendingPathComponent(destination.lastPathComponent + ".before-restore-" + Self.backupStamp(Date()), isDirectory: false)
                try? files.moveItem(at: destination, to: aside)
            }
            if let problem = Self.copy(kept, bytes: file.size, to: destination) {
                result.outcome = "Not restored: \(problem)"
                return result
            }
            put.append(destination.lastPathComponent)
        }
        if let here = session(offer.session.id) {
            result.outcome = put.isEmpty ? "Here already: left as it is."
                : "Here already; put back what it was missing: \(put.joined(separator: ", "))."
            if !put.isEmpty { Self.log("restored into \(here.info.title) (\(here.info.id)): \(put.joined(separator: ", "))") }
            return result
        }
        let when = Self.backupStamp(Date(timeIntervalSince1970: made))
        var notice = "Restored from a backup made on \(offer.from.isEmpty ? "this computer" : offer.from) (\(when))."
        if offer.session.container != nil { notice += " It ran in a container of its own, which Visor no longer makes: it runs on this computer now." }
        guard startCarried(offer, id: offer.session.id, cwd: cwd, notice: notice) != nil else {
            result.outcome = "Not restored: the session could not be started here."
            return result
        }
        result.outcome = "Restored."
        return result
    }

    // MARK: Files

    /// What a file of a backup is called there: its id, and what it is.
    static func backupName(of file: MigrationFile) -> String {
        let suffix = (file.place as NSString).pathExtension
        return file.id + "." + (file.packed ? "tgz" : suffix.isEmpty ? "data" : suffix)
    }

    /// "20261103-013108": a folder's name for when its backup was made.
    static func backupStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ n: Int?) -> String { n.map { $0 < 10 ? "0\($0)" : "\($0)" } ?? "00" }
        return "\(c.year ?? 0)\(two(c.month))\(two(c.day))-\(two(c.hour))\(two(c.minute))\(two(c.second))"
    }

    /// The first `bytes` of `source` to `destination`, a piece at a time
    /// (a conversation can run to gigabytes); what went wrong, if anything.
    static func copy(_ source: URL, bytes: Int, to destination: URL) -> String? {
        guard let reading = try? FileHandle(forReadingFrom: source) else { return "could not read \(source.path)" }
        defer { try? reading.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let writing = try? FileHandle(forWritingTo: destination) else { return "could not write \(destination.path)" }
        defer { try? writing.close() }
        var left = bytes
        do {
            while left > 0 {
                guard let piece = try reading.read(upToCount: min(left, migrationPiece)), !piece.isEmpty else { break }
                try writing.write(contentsOf: piece)
                left -= piece.count
            }
        } catch {
            return "could not copy \(source.path): \(error.localizedDescription)"
        }
        return left == 0 ? nil : "\(source.path) is shorter than it was"
    }

    /// A gzipped tar unpacked into `folder`.
    static func unpack(_ archive: URL, into folder: URL) async -> String? {
        let tar = ToolPath.resolve("tar") ?? "/usr/bin/tar"
        guard let result = await Command.output(tar, ["-xzf", archive.path, "-C", folder.path], errors: true) else { return "tar could not be started" }
        return result.status == 0 ? nil : result.text
    }

    static func write(_ json: JSONValue, to url: URL) throws {
        try Data(json.encoded().utf8).write(to: url, options: .atomic)
    }

    /// The bytes the files under `folder` come to.
    static func folderSize(_ folder: URL) -> Int {
        let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = walk?.nextObject() as? URL { total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}
