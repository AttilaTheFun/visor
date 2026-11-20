// Sessions backed up to a folder on this computer and restored from one
// (`/api/backups`; docs/protocol.md): each half of a move to another server
// (VisorServer+Migration.swift), with a folder in the middle, to keep
// sessions through an update that might lose them. A backup writes, for
// each session, what a move would carry — the agent's own files for its
// conversation (to its last whole line) and Claude's memory, never a
// project (Logan, 17 Nov: as a move) — beside the session as a move offers
// it. A restore puts back what is missing here and leaves what is here: a
// conversation file at least as long as the one kept stays (a shorter one
// is set aside, never removed), a memory there stays, a session still here
// is left as it is, and one that is gone is started again under its own
// id on the same conversation, in its folder (made empty when it is gone
// too). A backup may come from another computer, or be changed where it
// lies, so a restore holds it to what a move takes
// (VisorServer+MigrationContainment): the offer checked, and every archive
// checked and walked before anything is moved into place. An older
// backup's project archives are left out, said in the log.
//
//     <folder>/backup.json             what it holds (SessionBackup)
//     <folder>/<session>/offer.json    the session, as a move offers it
//     <folder>/<session>/<file>        its files (backupName)
//
// <session> is the id as SessionPathName names it (itself, for a UUID), so
// an id of `.` or `..` never names the backup's folder or its parent, which
// a failed item's folder is removed as.

import Foundation
import VisorAgent
import VisorProtocol
import VisorSystem

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
                reply = await backUp(body.sessionIDs, to: folder)
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
    func backUp(_ ids: [String]?, to chosen: URL?) async -> Envelope {
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
            items.append(await backUp(record, into: folder.appendingPathComponent(SessionPathName.of(record.info.id), isDirectory: true)))
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
    /// files.
    private func backUp(_ record: SessionRecord, into folder: URL) async -> SessionBackupItem {
        let item = { (outcome: String, kept: Bool) in SessionBackupItem(id: record.info.id, title: record.info.title, outcome: outcome, kept: kept) }
        guard let resume = record.process.resumeID, !resume.isEmpty else { return item("Not backed up: it has no conversation yet.", false) }
        if let failure = await keep(record, resume: resume, in: folder) { return item("Not backed up: \(failure.message)", false) }
        return item("Backed up.", true)
    }

    /// One session's offer and files written into `folder` (made when
    /// missing), as a backup keeps them and a session archive holds them
    /// (VisorServer+SessionArchive): why not, if they weren't, and then
    /// the folder is gone.
    func keep(_ record: SessionRecord, resume: String, in folder: URL) async -> MigrationFailure? {
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let carried: (offer: MigrationOffer, urls: [String: URL])
        switch await offer(of: record, resume: resume, token: "backup", packingInto: folder) {
        case .success(let made): carried = made
        case .failure(let failure):
            try? files.removeItem(at: folder)
            return failure
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
                return MigrationFailure(message: problem)
            }
        }
        do {
            try Self.write(carried.offer.json, to: folder.appendingPathComponent("offer.json", isDirectory: false))
        } catch {
            try? files.removeItem(at: folder)
            return MigrationFailure(message: error.localizedDescription)
        }
        return nil
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
            items.append(await restore(item, from: folder.appendingPathComponent(SessionPathName.of(item.id), isDirectory: true), made: backup.created,
                                       imported: backup.imported))
        }
        backup.sessions = items
        Self.log("restored from \(folder.path): " + items.map { "\($0.title) (\($0.id)): \($0.outcome)" }.joined(separator: "; "))
        var e = Envelope(type: "backup")
        e.backup = backup
        e.sessions = sessions.map(\.info)
        return e
    }

    /// One session put back: its conversation's files where missing or
    /// shorter, its memory where there is none, its folder where it is
    /// gone, and the session itself when it is gone. One `imported` from a
    /// session archive is refused while a session by its id is here
    /// (Logan: remove it first), before anything is put back.
    private func restore(_ item: SessionBackupItem, from folder: URL, made: Double, imported: Bool = false) async -> SessionBackupItem {
        var result = item
        if imported, let here = session(item.id) {
            result.outcome = "Not restored: “\(here.info.title)” (\(item.id)) is on this computer already. Remove it first, then restore it."
            return result
        }
        let files = FileManager.default
        guard let data = files.contents(atPath: folder.appendingPathComponent("offer.json").path),
              let stored = MigrationOffer(json: parseJSON(String(decoding: data, as: UTF8.self)) ?? .null) else {
            result.outcome = "Not restored: its files are not in the backup."
            return result
        }
        // A backup from before 0.61 may hold projects packed beside the
        // agent's files: left out, as a move leaves them.
        let (offer, projects) = Self.agentFilesOnly(stored)
        if !projects.isEmpty {
            Self.log("restore of \(offer.session.title) left out \(projects.map { Self.backupName(of: $0) }.joined(separator: ", ")): "
                + "projects an older backup packed; a backup carries the agent's own files only")
        }
        // A backup may come from another computer: held to what a move takes.
        if let problem = Self.unsafeOffer(offer) {
            result.outcome = "Not restored: \(problem)"
            return result
        }
        guard offer.session.id == item.id else {
            result.outcome = "Not restored: its files are of another session, \(offer.session.id)."
            return result
        }
        // Its folder: the server's own for the session, where it keeps one;
        // else where it was, under this home folder.
        let cwd = sessionFolders?.folder(agent: offer.session.agent, id: offer.session.id)
            ?? Self.path(offer.session.cwd, from: offer.home, to: SessionCatalog.home.path)
        var put: [String] = []
        // What each packed file unpacked to, which counts against the
        // restore's total in its place for what is unpacked after it.
        var landed: [String: Int] = [:]
        // The folder first: the agent starts in it.
        if !files.fileExists(atPath: cwd) {
            try? files.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            put.append(cwd + " (made empty)")
        }
        for file in offer.files where !file.place.isEmpty {
            let kept = folder.appendingPathComponent(Self.backupName(of: file), isDirectory: false)
            guard let destination = SessionCatalog.destination(of: file.place, agent: offer.session.agent, cwd: cwd, resume: offer.resumeID) else {
                result.outcome = "Not restored: nowhere to put \(file.place)."
                return result
            }
            try? files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.packed {
                // A folder (subagents' records): put back only when gone.
                guard !files.fileExists(atPath: destination.path) else { continue }
                let into = destination.deletingLastPathComponent()
                let limits = unpackLimits(file, of: offer.files, landed: landed, in: into)
                if let problem = await Self.unpack(kept, into: into, only: destination.lastPathComponent, limits: limits) {
                    result.outcome = "Not restored: could not unpack \(file.place): \(problem)"
                    return result
                }
                landed[file.id] = Self.unpackedBytes(destination)
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
        // Claude's memory, where the folder's project has none.
        if let memory = offer.files.first(where: { $0.id == Self.memoryFileID }),
           await Self.putMemory(folder.appendingPathComponent(Self.backupName(of: memory), isDirectory: false), of: offer.session.title, cwd: cwd,
                                limits: unpackLimits(memory, of: offer.files, landed: landed, in: Self.memoryProject(cwd))) {
            put.append("memory")
        }
        if let here = session(offer.session.id) {
            result.outcome = put.isEmpty ? "Here already: left as it is."
                : "Here already; put back what it was missing: \(put.joined(separator: ", "))."
            if !put.isEmpty { Self.log("restored into \(here.info.title) (\(here.info.id)): \(put.joined(separator: ", "))") }
            return result
        }
        let when = Self.backupStamp(Date(timeIntervalSince1970: made))
        let computer = offer.from.isEmpty ? "this computer" : offer.from
        var notice = imported ? "Restored from a session archive from \(computer), imported \(when)."
            : "Restored from a backup made on \(computer) (\(when))."
        if offer.session.container != nil { notice += " It ran in a container of its own, which Visor no longer makes: it runs on this computer now." }
        guard startCarried(offer, id: offer.session.id, cwd: cwd, notice: notice) != nil else {
            result.outcome = "Not restored: the session could not be started here."
            return result
        }
        result.outcome = "Restored."
        return result
    }

    /// The offer without the projects a backup from before 0.61 packed
    /// beside the agent's files (`project-<n>`, with no place), and those
    /// projects. Anything else stays, for the offer's checks to judge.
    static func agentFilesOnly(_ offer: MigrationOffer) -> (offer: MigrationOffer, projects: [MigrationFile]) {
        let isProject = { (file: MigrationFile) in file.place.isEmpty && file.id.hasPrefix("project-") }
        var agents = offer
        agents.files = offer.files.filter { !isProject($0) }
        return (agents, offer.files.filter(isProject))
    }

    // MARK: Files

    /// What a file of a backup is called there: its id, and what it is.
    static func backupName(of file: MigrationFile) -> String {
        let suffix = (file.place as NSString).pathExtension
        return file.id + "." + (file.packed ? "tgz" : suffix.isEmpty ? "data" : suffix)
    }

    /// "20261103-013108": a folder's name for when its backup was made.
    nonisolated static func backupStamp(_ date: Date) -> String {
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
