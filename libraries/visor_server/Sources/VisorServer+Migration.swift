// Moving a session to another server, through a client connected to both
// (`POST /api/migration/<step>`; the client's side is SessionMigration).
// Where the session is: an offer of it — the agent's own files for its
// conversation, and the projects it works in — read a piece at a time,
// with a project packed for copying when it cannot be cloned. Where it
// goes (VisorServer+MigrationArrival.swift): a plan of what will be done
// with each project, the files written, projects cloned or unpacked, and
// at the end the session started on the same conversation. The session it
// came from is left as it is, for the user to remove once the new one
// works.

import Foundation
import VisorProtocol

extension VisorServer {
    /// How much of a file one read gives.
    static let migrationPiece = 4 << 20
    /// How long an offer or a plan is kept, and what was packed or written
    /// for it.
    static let migrationLifetime: TimeInterval = 6 * 60 * 60

    static var migrationsFolder: URL { storeURL.deletingLastPathComponent().appendingPathComponent("migrations", isDirectory: true) }

    func routeMigration(_ step: String, body: Envelope, respond: @escaping (HTTPResponse) -> Void) {
        Task {
            let reply: Envelope
            switch step {
            case "offer": reply = await migrationOffer(body)
            case "read": reply = migrationRead(body)
            case "pack": reply = await migrationPack(body)
            case "plan": reply = await migrationPlan(body)
            case "write": reply = migrationWrite(body)
            case "clone": reply = await migrationClone(body)
            case "unpack": reply = await migrationUnpack(body)
            case "finish": reply = await migrationFinish(body)
            default: return respond(HTTPResponse(404, Envelope.error("No such step").encoded()))
            }
            respond(reply.type == "error" ? HTTPResponse(400, reply.encoded()) : .json(reply.encoded()))
        }
    }

    // MARK: Where the session is

    /// The session (`session`) offered for moving: its conversation's files
    /// (a folder packed), and its projects.
    func migrationOffer(_ body: Envelope) async -> Envelope {
        ageMigrations()
        guard let record = session(body.session) else { return .error("No such session") }
        guard record.info.container == nil else {
            return .error("“\(record.info.title)” runs in a container on oss: moving a session out of its container is not done yet.")
        }
        guard let resume = record.process.resumeID, !resume.isEmpty else {
            return .error("“\(record.info.title)” has no conversation to move yet: send it a message first.")
        }
        let token = UUID().uuidString.lowercased()
        let folder = Self.migrationsFolder.appendingPathComponent("out-" + token, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [MigrationFile] = []
        var urls: [String: URL] = [:]
        for (index, file) in SessionCatalog.conversationFiles(agent: record.info.agent, id: resume, cwd: record.info.cwd).enumerated() {
            let id = "conversation-\(index)"
            if file.folder {
                let archive = folder.appendingPathComponent(id + ".tgz", isDirectory: false)
                if let problem = await Self.pack(folder: file.url, into: archive) { return .error("Could not pack \(file.url.path): \(problem)") }
                urls[id] = archive
                files.append(MigrationFile(id: id, place: file.place, size: Self.fileSize(archive), packed: true))
            } else {
                urls[id] = file.url
                files.append(MigrationFile(id: id, place: file.place, size: Self.wholeLines(of: file.url), packed: false))
            }
        }
        guard files.contains(where: { !$0.packed }) else { return .error("The agent's own record of “\(record.info.title)” is not on this computer.") }
        let home = SessionCatalog.home.path
        let projects = await ProjectSurvey.projects(cwd: record.info.cwd, conversation: urls["conversation-0"], home: home)
        migrationsOut[token] = OutgoingMigration(session: record.info.id, files: urls, folder: folder, created: Date())
        var info = record.info
        info.cwd = (info.cwd as NSString).expandingTildeInPath
        var e = Envelope(type: "migration")
        e.offer = MigrationOffer(token: token, from: hostName, session: info, resumeID: resume, home: home, files: files, projects: projects)
        return e
    }

    /// A piece of one of an offer's files (`migration`, `file`): from
    /// `offset`, base64 in `data`, and where the next piece starts.
    func migrationRead(_ body: Envelope) -> Envelope {
        guard let token = body.migration, let offer = migrationsOut[token] else { return .error("That move has ended; start it again.") }
        guard let id = body.file?.id, let url = offer.files[id] else { return .error("No such file") }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .error("Could not read \(url.path)") }
        defer { try? handle.close() }
        let offset = max(0, body.offset ?? 0)
        let limit = min(Self.migrationPiece, max(1, body.file?.size ?? Self.migrationPiece))
        do {
            try handle.seek(toOffset: UInt64(offset))
            let piece = try handle.read(upToCount: limit) ?? Data()
            var e = Envelope(type: "migration")
            e.data = piece.base64EncodedString()
            e.offset = offset + piece.count
            return e
        } catch {
            return .error("Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    /// A project of the offer's (`path`) packed for copying: the file to
    /// read it from.
    func migrationPack(_ body: Envelope) async -> Envelope {
        guard let token = body.migration, var offer = migrationsOut[token] else { return .error("That move has ended; start it again.") }
        guard let path = body.path, let top = await ProjectSurvey.toplevel(of: path), top == path else {
            return .error("\(body.path ?? "That") is not a git repository here.")
        }
        let id = "project-\(offer.files.count)"
        let archive = offer.folder.appendingPathComponent(id + ".tgz", isDirectory: false)
        if let problem = await ProjectSurvey.pack(top, into: archive) { return .error("Could not pack \(top): \(problem)") }
        offer.files[id] = archive
        migrationsOut[token] = offer
        var e = Envelope(type: "migration")
        e.file = MigrationFile(id: id, place: "", size: Self.fileSize(archive), packed: true)
        return e
    }

    // MARK: Keeping

    /// Offers and plans past their time go, with what was packed or written
    /// for them.
    func ageMigrations(now: Date = Date()) {
        for (token, offer) in migrationsOut where now.timeIntervalSince(offer.created) > Self.migrationLifetime {
            try? FileManager.default.removeItem(at: offer.folder)
            migrationsOut[token] = nil
        }
        for (id, move) in migrationsIn where now.timeIntervalSince(move.created) > Self.migrationLifetime {
            try? FileManager.default.removeItem(at: move.folder)
            migrationsIn[id] = nil
        }
    }

    /// A folder packed as one file: a gzipped tar of it, by its own name.
    static func pack(folder: URL, into archive: URL) async -> String? {
        let tar = ToolPath.resolve("tar") ?? "/usr/bin/tar"
        guard let result = await Command.output(tar, ["-czf", archive.path, "-C", folder.deletingLastPathComponent().path, folder.lastPathComponent],
                                                errors: true) else { return "tar could not be started" }
        return result.status == 0 ? nil : result.text
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// The file's length up to the end of its last whole line: a
    /// conversation still being written is carried up to what is finished.
    static func wholeLines(of url: URL) -> Int {
        let size = fileSize(url)
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return size }
        defer { try? handle.close() }
        let tail = min(size, 1 << 20)
        guard (try? handle.seek(toOffset: UInt64(size - tail))) != nil, let end = try? handle.read(upToCount: tail),
              let newline = end.lastIndex(of: 0x0A) else { return size }
        return size - tail + (newline - end.startIndex) + 1
    }
}
