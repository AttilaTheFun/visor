// Session archives, "Session archive v1" (`POST /api/sessions/<id>/export`,
// `POST /api/import`; docs/protocol.md): one session in one file,
// `<title>-<date>.visorsession`, to keep, to carry by hand, or for a CI
// job to write. It is a backup's folder for that one session
// (VisorServer+Backups) as a tar:
//
//     session/offer.json        the session, as a move offers it
//     session/<id>.<suffix>     its files, as a backup names them
//                               (backupName): the transcript, the folder
//                               beside it and Claude's memory, each folder
//                               a gzipped tar of its own
//
// held to a move's caps (VisorServer+MigrationSize: 2 GiB a file, 4 GiB in
// all, 200,000 entries an archive). It is gzipped, not zstd-compressed:
// the tar on a stock Mac (bsdtar 3.5, built without libzstd) and Windows'
// have zstd only through a `zstd` program, which neither has, while every
// tar Visor runs on reads and writes gzip (a move's folders are gzipped
// already). An import takes one gzipped or plain, as tar finds it.
//
// An export writes it beside the server's moves (or at a path on this
// computer), and the client reads it a piece at a time as a move's file
// (`POST /api/migration/read`, the file `archive`). An import takes it
// from a path on this computer, or uploaded a piece at a time, and holds
// it to what a move takes and a restore applies, with their own code
// (VisorServer+MigrationContainment): the archive unpacked as its one
// folder, every name, link and size checked; the offer checked
// (unsafeOffer); each file the size the offer says; each archive in it
// listed and held to the caps (vetted). Then it is kept in the backups
// store as a backup of its own, `imported`, which a restore puts back on
// this computer: refused while a session by its id is here, and never
// touching the computer it came from.

import Foundation
import VisorAgent
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// A session archive's extension.
    static let sessionArchiveExtension = "visorsession"
    /// The one folder a session archive holds.
    static let sessionArchiveFolder = "session"
    /// An export's one file, as `/api/migration/read` names it.
    static let sessionArchiveFileID = "archive"
    /// The most a session archive may be, or unpack to: a move's files at
    /// most (migrationTotalCap), with its offer and tar's own headers.
    nonisolated static let sessionArchiveCap = migrationTotalCap + (16 << 20)
    /// The most entries a session archive may hold: its folder, its offer
    /// and its files (three at most), with room to spare. Each archive in
    /// it is held to unpackEntryCap of its own.
    nonisolated static let sessionArchiveEntryCap = 16

    // MARK: Export

    /// The session `id` as a session archive: at `path` on this computer
    /// when one is given (a folder: the archive by its own name in it; never
    /// over a file), else kept for the client to read (`migration`, the file
    /// `archive`) as long as a move's offer is. Its name and size are in
    /// `file` (`place`, `size`). Refused, with what would help, when the
    /// conversation is more than an archive holds (tooLarge).
    func exportSession(_ id: String, to path: String?) async -> Envelope {
        ageMigrations()
        guard let record = session(id) else { return .error("No such session") }
        guard let resume = record.process.resumeID, !resume.isEmpty else {
            return .error("“\(record.info.title)” has no conversation to export yet: send it a message first.")
        }
        let files = FileManager.default
        let token = UUID().uuidString.lowercased()
        let folder = Self.migrationsFolder.appendingPathComponent("export-" + token, isDirectory: true)
        let kept = folder.appendingPathComponent(Self.sessionArchiveFolder, isDirectory: true)
        if let failure = await keep(record, resume: resume, in: kept) {
            try? files.removeItem(at: folder)
            return .error(failure.message)
        }
        let name = Self.archiveName(title: record.info.title, date: Date())
        let archive = folder.appendingPathComponent(name, isDirectory: false)
        let packed = await Self.pack(folder: kept, into: archive)
        Self.removeTree(kept)
        if let packed {
            try? files.removeItem(at: folder)
            return .error("Could not write the archive of “\(record.info.title)”: \(packed)")
        }
        let size = Self.fileSize(archive)
        var e = Envelope(type: "export")
        e.file = MigrationFile(id: Self.sessionArchiveFileID, place: name, size: size, packed: true)
        if let path, !path.isEmpty {
            defer { try? files.removeItem(at: folder) }
            var destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false)
            var isFolder: ObjCBool = false
            if files.fileExists(atPath: destination.path, isDirectory: &isFolder), isFolder.boolValue {
                destination = destination.appendingPathComponent(name, isDirectory: false)
            }
            guard !files.fileExists(atPath: destination.path) else { return .error("\(destination.path) is there already: an export never writes over a file.") }
            do { try files.moveItem(at: archive, to: destination) } catch {
                return .error("Could not write \(destination.path): \(error.localizedDescription)")
            }
            e.path = destination.path
        } else {
            migrationsOut[token] = OutgoingMigration(session: id, files: [Self.sessionArchiveFileID: archive], folder: folder, created: Date())
            e.migration = token
        }
        Self.log("exported \(record.info.title) (\(id)) as \(name), \(Self.megabytes(size))")
        return e
    }

    /// "Offline sync-2026-11-20.visorsession": a session archive's name, of
    /// the session's title (what a file's name can't hold made `-`) and the
    /// day (UTC).
    nonisolated static func archiveName(title: String, date: Date) -> String {
        let unsafe = Set("/\\:*?\"<>|")
        var cleaned = String(title.map { unsafe.contains($0) || ($0.asciiValue ?? 32) < 32 || $0.isNewline ? "-" : $0 })
        cleaned = String(cleaned.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))).prefix(80))
        if cleaned.isEmpty { cleaned = "Session" }
        let stamp = Array(backupStamp(date).prefix(8))
        let day = String(stamp[0..<4]) + "-" + String(stamp[4..<6]) + "-" + String(stamp[6..<8])
        return cleaned + "-" + day + "." + sessionArchiveExtension
    }

    // MARK: Import

    /// `POST /api/import` with a `path` on this computer, or with `file`
    /// (its `size`, its name as `place`) to upload it; `/import/write` a
    /// piece of the upload; `/import/finish` the upload imported.
    func routeImport(_ request: HTTPRequest, parts: [String], respond: @escaping (HTTPResponse) -> Void) {
        let body = Envelope.decodeBody(request.body)
        Task {
            let reply: Envelope
            switch parts.count == 2 ? parts[1] : "" {
            case "":
                if let path = body.path, !path.isEmpty {
                    reply = await importArchive(at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false))
                } else {
                    reply = importUpload(body)
                }
            case "write": reply = importWrite(body)
            case "finish": reply = await importFinish(body)
            default: return respond(HTTPResponse(404, Envelope.error("No such step").encoded()))
            }
            respond(reply.type == "error" ? HTTPResponse(400, reply.encoded()) : .json(reply.encoded()))
        }
    }

    /// An upload begun of an archive of `file.size` bytes (`file.place` its
    /// name): the token its pieces are written with (`migration`).
    func importUpload(_ body: Envelope) -> Envelope {
        ageMigrations()
        guard let file = body.file, file.size > 0 else { return .error("Which session archive: a path on this computer, or one to upload (file.size)?") }
        let name = file.place.isEmpty ? "The archive" : file.place
        guard file.size <= Self.sessionArchiveCap else { return .error(Self.archiveTooLarge(name, size: file.size)) }
        if let free = freeBytes(Self.migrationsFolder), free < file.size + Self.migrationFreeMargin {
            return .error("\(name) was not imported: \(Self.migrationsFolder.path) has \(Self.megabytes(free)) free, and it needs "
                + "\(Self.megabytes(file.size)) with \(Self.megabytes(Self.migrationFreeMargin)) to spare.")
        }
        let token = UUID().uuidString.lowercased()
        let folder = Self.migrationsFolder.appendingPathComponent("import-" + token, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let upload = folder.appendingPathComponent("archive." + Self.sessionArchiveExtension, isDirectory: false)
        importsIn[token] = IncomingImport(file: upload, size: file.size, name: name, folder: folder, created: Date())
        var e = Envelope(type: "import")
        e.migration = token
        e.offset = 0
        return e
    }

    /// A piece of an upload (`migration`), at `offset`, base64 in `data`:
    /// where the next starts. Never past the size it began with.
    func importWrite(_ body: Envelope) -> Envelope {
        guard let token = body.migration, let upload = importsIn[token] else { return .error("That import has ended; start it again.") }
        guard let data = body.data.flatMap({ Data(base64Encoded: $0) }) else { return .error("A piece's bytes are required") }
        switch Self.writePiece(data, at: body.offset ?? 0, to: upload.file, declared: upload.size, name: upload.name) {
        case .success(let next):
            var e = Envelope(type: "import")
            e.offset = next
            return e
        case .failure(let refusal):
            return .error(refusal.message)
        }
    }

    /// The upload (`migration`), whole, imported (importArchive); what was
    /// uploaded goes either way.
    func importFinish(_ body: Envelope) async -> Envelope {
        guard let token = body.migration, let upload = importsIn[token] else { return .error("That import has ended; start it again.") }
        guard Self.fileSize(upload.file) == upload.size else {
            return .error("Not all of \(upload.name) was uploaded (\(Self.fileSize(upload.file)) of \(upload.size) bytes); start the import again.")
        }
        let reply = await importArchive(at: upload.file, named: upload.name)
        try? FileManager.default.removeItem(at: upload.folder)
        importsIn[token] = nil
        return reply
    }

    /// The session archive at `archive` (`name`, as the person knows it),
    /// held to what a move takes and a restore applies (above), kept in the
    /// backups store as a backup of its own, imported: that backup, or why
    /// not (and nothing of it kept). `entryCap` is what each archive in it
    /// may hold (unpackEntryCap; a test's fewer).
    func importArchive(at archive: URL, named given: String? = nil, entryCap: Int = VisorServer.unpackEntryCap) async -> Envelope {
        let name = given ?? archive.lastPathComponent
        let files = FileManager.default
        guard (try? files.attributesOfItem(atPath: archive.path))?[.type] as? FileAttributeType == .typeRegular else {
            return .error("There is no session archive at \(archive.path).")
        }
        let size = Self.fileSize(archive)
        guard size <= Self.sessionArchiveCap else { return .error(Self.archiveTooLarge(name, size: size)) }
        let now = Date()
        let folder = Self.newBackupFolder(Self.backupStamp(now) + "-import")
        do { try files.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return .error("Could not make \(folder.path): \(error.localizedDescription)")
        }
        var kept = false
        defer { if !kept { Self.removeTree(folder) } }
        let refused = { (why: String) in Envelope.error("\(name) was not imported: \(why).") }
        // The archive as one folder, as a move's folder is unpacked.
        let limits = UnpackLimits(fileCap: Self.sessionArchiveCap, budget: Self.sessionArchiveCap, free: freeBytes(folder),
                                  entries: Self.sessionArchiveEntryCap)
        if let problem = await Self.unpack(archive, into: folder, only: Self.sessionArchiveFolder, limits: limits, gzip: false) {
            return refused(problem)
        }
        let unpacked = folder.appendingPathComponent(Self.sessionArchiveFolder, isDirectory: true)
        guard let data = files.contents(atPath: unpacked.appendingPathComponent("offer.json").path),
              let offer = MigrationOffer(json: parseJSON(String(decoding: data, as: UTF8.self)) ?? .null) else {
            return refused("it holds no offer.json that Visor can read")
        }
        // Its offer as a move's and a restore's, and its files as it says.
        if let problem = Self.unsafeOffer(offer) { return refused(problem) }
        if let problem = await Self.unsafeArchiveFiles(offer, in: unpacked, entryCap: entryCap) { return refused(problem) }
        let named = folder.appendingPathComponent(SessionPathName.of(offer.session.id), isDirectory: true)
        if named.path != unpacked.path {
            do { try files.moveItem(at: unpacked, to: named) } catch { return refused(error.localizedDescription) }
        }
        let item = SessionBackupItem(id: offer.session.id, title: offer.session.title, outcome: "Imported.", kept: true)
        let backup = SessionBackup(path: folder.path, created: now.timeIntervalSince1970, from: offer.from, sessions: [item],
                                   size: Self.folderSize(folder), imported: true)
        do { try Self.write(backup.json, to: folder.appendingPathComponent("backup.json", isDirectory: false)) } catch {
            return .error("Could not write \(folder.path)/backup.json: \(error.localizedDescription)")
        }
        kept = true
        Self.log("imported \(name): \(offer.session.title) (\(offer.session.id)) from \(offer.from), kept at \(folder.path)")
        var e = Envelope(type: "backup")
        e.backup = backup
        return e
    }

    /// Why the files of a session archive, unpacked at `folder`, aren't
    /// what its offer says: anything there but offer.json and the offer's
    /// files (by backupName), one missing, one that isn't a plain file or
    /// isn't the size the offer says, or an archive among them that a
    /// restore would refuse before unpacking it (vetted: its names, its
    /// entries, past `entryCap`, and the sizes it declares). Nil when they
    /// are.
    static func unsafeArchiveFiles(_ offer: MigrationOffer, in folder: URL, entryCap: Int) async -> String? {
        let files = FileManager.default
        let expected = Set(["offer.json"] + offer.files.map(backupName(of:)))
        let present = Set((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
        if let extra = present.subtracting(expected).sorted().first { return "it holds \(extra), which its offer doesn't name" }
        if let missing = expected.subtracting(present).sorted().first { return "it lacks \(missing), which its offer names" }
        let tar = ToolPath.resolve("tar") ?? "/usr/bin/tar"
        for file in offer.files {
            let name = backupName(of: file)
            let url = folder.appendingPathComponent(name, isDirectory: false)
            guard (try? files.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular else {
                return "its \(name) is not a plain file"
            }
            let size = fileSize(url)
            guard size == file.size else { return "its \(name) is \(size) bytes, and its offer says \(file.size)" }
            guard file.packed else { continue }
            // As a restore unpacks it: the folder by its place's name, or
            // the memory.
            let only = file.place.isEmpty ? "memory" : (file.place as NSString).lastPathComponent
            let others = offer.files.filter { $0.id != file.id }.reduce(0) { $0 + max(0, $1.size) }
            let limits = UnpackLimits(budget: migrationTotalCap - others, entries: entryCap)
            if case .failure(let refusal) = await vetted(url, only: only, limits: limits, in: folder, tar: tar) {
                return "its \(name) can't be unpacked: \(refusal.message)"
            }
        }
        return nil
    }

    /// Why an archive of `size` bytes is more than a session archive is.
    nonisolated static func archiveTooLarge(_ name: String, size: Int) -> String {
        "\(name) was not imported: it is \(megabytes(size)), and a session archive holds at most \(megabytes(migrationTotalCap)) "
            + "of a session's files."
    }

    /// A new folder in backupsFolder named `name` (`name-2`, … when taken).
    static func newBackupFolder(_ name: String) -> URL {
        var folder = backupsFolder.appendingPathComponent(name, isDirectory: true)
        var count = 1
        while FileManager.default.fileExists(atPath: folder.path) {
            count += 1
            folder = backupsFolder.appendingPathComponent("\(name)-\(count)", isDirectory: true)
        }
        return folder
    }
}
