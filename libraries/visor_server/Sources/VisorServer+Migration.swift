// Moving a session to another server, through a client connected to both
// (`POST /api/migration/<step>`; the client's side is SessionMigration).
// A move carries the agent's own files for the conversation and nothing
// else (Logan, 17 Nov): its transcript, the folder the agent keeps beside
// it (Claude's subagents and long tool results), and Claude's memory. No
// project, working tree or clone: the session runs in a new, empty folder
// there, and its agent clones what it needs. Where the session is: an
// offer of it, read a piece at a time. Where it goes
// (VisorServer+MigrationArrival.swift): a plan (the new folder), the files
// written, and at the end the session started on the same conversation.
// The session it came from is left as it is, for the user to remove once
// the new one works. Peers are only the user's own paired servers
// (docs/protocol.md); what one offers is held to what a move takes all the
// same (VisorServer+MigrationContainment.swift).

import Foundation
import VisorAgent
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// How much of a file one read gives.
    static let migrationPiece = 4 << 20
    /// How long an offer or a plan is kept, and what was packed or written
    /// for it.
    static let migrationLifetime: TimeInterval = 6 * 60 * 60

    /// What a client before 0.61 is told when it asks for a project to be
    /// packed, cloned or unpacked.
    static let projectStepsRemoved = "Moving a session's projects was removed in Visor 0.61: a move carries the agent's own files, "
        + "and the session's agent clones what it needs on the other computer. Update Visor on this device."

    static var migrationsFolder: URL { storeURL.deletingLastPathComponent().appendingPathComponent("migrations", isDirectory: true) }

    func routeMigration(_ step: String, body: Envelope, respond: @escaping (HTTPResponse) -> Void) {
        Task {
            let reply: Envelope
            switch step {
            case "offer":
                // In the Sessions container: its turns there are in the
                // container's Claude folder, which an offer doesn't read.
                if let record = session(body.session), isInContainer(record) {
                    return respond(HTTPResponse(409, Envelope.error(Self.containerMigrationRefusal(record)).encoded()))
                }
                reply = await migrationOffer(body)
            case "read": reply = migrationRead(body)
            case "plan": reply = await migrationPlan(body)
            case "write": reply = migrationWrite(body)
            case "finish": reply = await migrationFinish(body)
            // A client before 0.61 asks these to bring a session's projects.
            case "pack", "clone", "unpack": return respond(HTTPResponse(410, Envelope.error(Self.projectStepsRemoved).encoded()))
            default: return respond(HTTPResponse(404, Envelope.error("No such step").encoded()))
            }
            respond(reply.type == "error" ? HTTPResponse(400, reply.encoded()) : .json(reply.encoded()))
        }
    }

    // MARK: Where the session is

    /// Why a session in the Sessions container isn't offered to another
    /// computer: its conversation there would be left behind.
    static func containerMigrationRefusal(_ record: SessionRecord) -> String {
        "“\(record.info.title)” is in the Sessions container: move it back to this computer first, so its conversation there comes with it."
    }

    /// The session (`session`) offered for moving: its conversation's files
    /// (a folder packed). Refused for one in the Sessions container
    /// (routeMigration answers that 409).
    func migrationOffer(_ body: Envelope) async -> Envelope {
        ageMigrations()
        guard let record = session(body.session) else { return .error("No such session") }
        guard !isInContainer(record) else { return .error(Self.containerMigrationRefusal(record)) }
        guard let resume = record.process.resumeID, !resume.isEmpty else {
            return .error("“\(record.info.title)” has no conversation to move yet: send it a message first.")
        }
        let token = UUID().uuidString.lowercased()
        let folder = Self.migrationsFolder.appendingPathComponent("out-" + token, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let carried: (offer: MigrationOffer, urls: [String: URL])
        switch await offer(of: record, resume: resume, token: token, packingInto: folder) {
        case .success(let made): carried = made
        case .failure(let failure): return .error(failure.message)
        }
        migrationsOut[token] = OutgoingMigration(session: record.info.id, files: carried.urls, folder: folder, created: Date())
        var e = Envelope(type: "migration")
        e.offer = carried.offer
        return e
    }

    /// A session as a move offers it (or a backup or an export keeps it): its
    /// conversation's files — each by an id, where it is here, a folder
    /// packed into `folder` first, a file to its last whole line — and
    /// Claude's memory with them; refused when a file, or all of them, is
    /// more than a move carries (migrationFileCap, migrationTotalCap), in
    /// words that name it, its size and what would help (tooLarge).
    func offer(of record: SessionRecord, resume: String, token: String,
               packingInto folder: URL) async -> Result<(offer: MigrationOffer, urls: [String: URL]), MigrationFailure> {
        var files: [MigrationFile] = []
        var urls: [String: URL] = [:]
        // Where each is here, for a refusal to name.
        var sources: [String: URL] = [:]
        for (index, file) in SessionCatalog.conversationFiles(agent: record.info.agent, id: resume, cwd: record.info.cwd).enumerated() {
            let id = "conversation-\(index)"
            sources[id] = file.url
            if file.folder {
                let archive = folder.appendingPathComponent(id + ".tgz", isDirectory: false)
                if let problem = await Self.pack(folder: file.url, into: archive) {
                    return .failure(MigrationFailure(message: "Could not pack \(file.url.path): \(problem)"))
                }
                urls[id] = archive
                files.append(MigrationFile(id: id, place: file.place, size: Self.fileSize(archive), packed: true))
            } else {
                urls[id] = file.url
                files.append(MigrationFile(id: id, place: file.place, size: Self.wholeLines(of: file.url), packed: false))
            }
        }
        // A Claude conversation's project memory with it, where Claude Code
        // keeps it (VisorServer+MigrationMemory).
        if record.info.agent == .claude, let conversation = urls["conversation-0"],
           let memory = await Self.packMemory(of: conversation, cwd: record.info.cwd, into: folder) {
            urls[memory.file.id] = memory.url
            sources[memory.file.id] = memory.source
            files.append(memory.file)
        }
        guard files.contains(where: { !$0.packed }) else {
            return .failure(MigrationFailure(message: "The agent's own record of “\(record.info.title)” is not on this computer."))
        }
        if let problem = Self.tooLarge(files, at: sources, title: record.info.title) {
            return .failure(MigrationFailure(message: problem))
        }
        var info = record.info
        info.cwd = (info.cwd as NSString).expandingTildeInPath
        let offer = MigrationOffer(token: token, from: hostName, session: info, resumeID: resume, home: SessionCatalog.home.path, files: files)
        return .success((offer, urls))
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

    // MARK: Keeping

    /// Offers (and exports), plans and imports' uploads past their time go,
    /// with what was packed or written for them.
    func ageMigrations(now: Date = Date()) {
        for (token, offer) in migrationsOut where now.timeIntervalSince(offer.created) > Self.migrationLifetime {
            try? FileManager.default.removeItem(at: offer.folder)
            migrationsOut[token] = nil
        }
        for (id, move) in migrationsIn where now.timeIntervalSince(move.created) > Self.migrationLifetime {
            try? FileManager.default.removeItem(at: move.folder)
            migrationsIn[id] = nil
        }
        for (token, upload) in importsIn where now.timeIntervalSince(upload.created) > Self.migrationLifetime {
            try? FileManager.default.removeItem(at: upload.folder)
            importsIn[token] = nil
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
