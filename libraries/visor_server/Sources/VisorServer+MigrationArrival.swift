// A session moving here from another server (VisorServer+Migration.swift):
// a plan of where it runs — a new, empty folder this server chooses, never
// a path of the other server's — the agent's files the client carries
// written a piece at a time, and at the end those files put where the
// agent here keeps that conversation (and Claude's memory under the new
// folder's project), and the session started on the same conversation.

import Foundation
import VisorAgent
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// Where a session moved here works when the server keeps no folder for
    /// each session (VISOR_SESSIONS_DIR): a folder of its own under Visor's
    /// data folder, <data>/Sessions/<agent>/<id>, as SessionFolders makes
    /// them.
    static var movedSessionsFolder: URL { HostFolders.dataFolder.appendingPathComponent("Sessions", isDirectory: true) }

    /// The folders sessions moved here are made in: the server's own for
    /// each session, else under movedSessionsFolder.
    var arrivalFolders: SessionFolders { sessionFolders ?? SessionFolders(sessions: Self.movedSessionsFolder.path) }

    /// What this server will do with the session offered (`offer`): the
    /// session's id here, and its new, empty folder made of it (`cwd`),
    /// which is where its agent clones what it needs. Refused for an offer
    /// that isn't only the agent's own files for one conversation, within
    /// what a move carries (VisorServer+MigrationContainment,
    /// VisorServer+MigrationSize), or that would not fit here; and, in a
    /// container, where that folder is not one its computer shares.
    func migrationPlan(_ body: Envelope) async -> Envelope {
        ageMigrations()
        guard let offer = body.offer, let harness = harnesses.harness(for: offer.session.agent) else {
            return .error("This server does not run that kind of session.")
        }
        let from = offer.from.isEmpty ? "the other computer" : offer.from
        if let problem = Self.unsafeOffer(offer) { return .error("The move from \(from) was refused: \(problem).") }
        if let problem = noRoom(for: offer.files, agent: offer.session.agent) {
            return .error("The move from \(from) was refused: there is not room for it here: \(problem).")
        }
        let sessionID = Self.newSessionID()
        let cwd = arrivalFolders.folder(agent: offer.session.agent, id: sessionID)
        // In a container, a session works in a folder its computer shares
        // with it, or it would be on the container's own disk.
        if let shared = ServerPlatform.current.host.sharedFolders(), !shared.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) {
            return .error(Self.notShared(cwd, shared: shared))
        }
        let id = UUID().uuidString.lowercased()
        let plan = MigrationPlan(id: id, cwd: cwd, agentInstalled: harness.available)
        let folder = Self.migrationsFolder.appendingPathComponent("in-" + id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        migrationsIn[id] = IncomingMigration(offer: offer, plan: plan, folder: folder, created: Date(), sessionID: sessionID)
        var e = Envelope(type: "migration")
        e.plan = plan
        return e
    }

    /// A piece of a file the client carries (`migration`, `file`), at
    /// `offset`: the first piece starts it, each next one follows on.
    func migrationWrite(_ body: Envelope) -> Envelope {
        guard let id = body.migration, let move = migrationsIn[id] else { return .error("That move has ended; start it again.") }
        guard let file = body.file?.id, let data = body.data.flatMap({ Data(base64Encoded: $0) }) else {
            return .error("A file and its bytes are required")
        }
        guard let url = Self.carried(file, in: move.folder) else { return .error("“\(file)” is not a name a move's file has.") }
        // Only a file the offer named, and never past the size it said.
        guard let declared = move.offer.files.first(where: { $0.id == file }) else { return .error("“\(file)” is not a file of this move.") }
        let offset = body.offset ?? 0
        guard offset >= 0, offset <= declared.size, data.count <= declared.size - offset else {
            return .error("That piece runs past the \(declared.size) bytes “\(file)” was offered as.")
        }
        // The last piece sent again (its answer lost on the way back): what
        // is here already ends with the same bytes, so it is taken as written.
        let size = Self.fileSize(url)
        if offset < size, offset + data.count == size, Self.endsWith(url, data) {
            var e = Envelope(type: "migration")
            e.offset = size
            return e
        }
        if offset == 0 { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard Self.fileSize(url) == offset, let handle = try? FileHandle(forWritingTo: url) else {
            return .error("That piece does not follow on from what was written (\(Self.fileSize(url)) bytes).")
        }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return .error("Could not write: \(error.localizedDescription)")
        }
        var e = Envelope(type: "migration")
        e.offset = offset + data.count
        return e
    }

    /// The end of a move: the conversation's files put where the agent here
    /// keeps them for the plan's folder, the folder made, new and empty,
    /// and the session started there on the same conversation, told where
    /// it came from. The new session's id is in `session`. (A client before
    /// 0.61 also sent the projects' `steps` and a `cwd` of its choosing,
    /// which are passed over: the session's folder is the plan's.)
    func migrationFinish(_ body: Envelope) async -> Envelope {
        guard let id = body.migration, let move = migrationsIn[id] else { return .error("That move has ended; start it again.") }
        let offer = move.offer
        // Held again here, before anything is made, whatever the plan took.
        if let problem = Self.unsafeOffer(offer) { return .error("The move was refused: \(problem).") }
        let cwd = move.plan.cwd
        if FileManager.default.fileExists(atPath: cwd), (try? FileManager.default.contentsOfDirectory(atPath: cwd))?.isEmpty != true {
            return .error("The move was refused: \(cwd), the session's new folder, is not empty.")
        }
        let files = FileManager.default
        // Where each file goes, all of them known before anything is made.
        // A packed folder first: unpacked whole or not at all, so one that
        // is refused leaves the conversation's file where it was carried.
        var placed: [(file: MigrationFile, carried: URL, destination: URL, there: URL?)] = []
        for file in offer.files.filter(\.packed) + offer.files.filter({ !$0.packed }) where !file.place.isEmpty {
            guard let carried = Self.carried(file.id, in: move.folder) else { return .error("“\(file.id)” is not a name a move's file has.") }
            guard Self.fileSize(carried) == file.size else { return .error("Not all of the conversation was carried here; start the move again.") }
            guard let destination = SessionCatalog.destination(of: file.place, agent: offer.session.agent, cwd: cwd, resume: offer.resumeID) else {
                return .error("Nowhere to put \(file.place)")
            }
            placed.append((file, carried, destination, Self.alreadyHere(file, at: destination, agent: offer.session.agent, resume: offer.resumeID)))
        }
        if let problem = Self.notComingBack(placed.map { ($0.file, $0.carried, $0.there) }) { return .error("The move was refused: \(problem).") }
        try? files.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let stamp = Self.backupStamp(Date())
        // What each packed file unpacked to, which counts against the
        // move's total in its place for what is unpacked after it.
        var landed: [String: Int] = [:]
        for (file, carried, destination, there) in placed {
            try? files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The same conversation come back: its log here, the start of
            // the one carried, is replaced; anything else set aside.
            var aside: (from: URL, to: URL)?
            if let there, file.packed || there != destination || !Self.isPrefix(there, of: carried) {
                let to = there.deletingLastPathComponent().appendingPathComponent(there.lastPathComponent + ".before-move-" + stamp, isDirectory: false)
                do { try files.moveItem(at: there, to: to) } catch {
                    return .error("Could not set \(there.path) aside: \(error.localizedDescription)")
                }
                aside = (there, to)
            }
            if file.packed {
                // The folder by its own name alone, where nothing is; what
                // was set aside for it back again when it can't be.
                let into = destination.deletingLastPathComponent()
                let limits = unpackLimits(file, of: offer.files, landed: landed, in: into)
                if let problem = await Self.unpack(carried, into: into, only: destination.lastPathComponent, limits: limits) {
                    if let aside { try? files.moveItem(at: aside.to, to: aside.from) }
                    return .error("Could not put the conversation at \(destination.path): \(problem)")
                }
                landed[file.id] = Self.unpackedBytes(destination)
            } else {
                try? files.removeItem(at: destination)
                do { try files.moveItem(at: carried, to: destination) } catch {
                    return .error("Could not put the conversation at \(destination.path): \(error.localizedDescription)")
                }
            }
        }
        let notice = "Moved here from \(offer.from.isEmpty ? "another computer" : offer.from). The session there is as it was: remove it once this one works."
        await putMemory(of: move, cwd: cwd, landed: landed)
        guard let record = startCarried(offer, id: move.sessionID, cwd: cwd, notice: notice) else {
            return .error("The session could not be started here.")
        }
        Self.log("session moved here from \(offer.from): \(offer.session.title) (\(record.info.id))")
        try? files.removeItem(at: move.folder)
        migrationsIn[id] = nil
        var e = Envelope(type: "migration")
        e.session = record.info.id
        e.sessions = sessions.map(\.info)
        return e
    }

    /// What is here already for a carried file that goes to
    /// `destination`: what is there, or, for Codex's rollout, the thread's
    /// rollout wherever Codex keeps it (it finds a thread by its id, not
    /// by the day it began). Nil when nothing is.
    static func alreadyHere(_ file: MigrationFile, at destination: URL, agent: AgentKind, resume: String) -> URL? {
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil { return destination }
        guard agent == .codex, !file.packed else { return nil }
        return SessionCatalog.codexRollout(id: resume)
    }

    /// Why a move's files can't go where something is already (`there`):
    /// nil when nothing is, or when it is the same conversation coming back.
    /// The same conversation is the same agent's under the same id (each
    /// file's place here is made of both, so whatever is there is that
    /// agent's for that id) whose every log (`.jsonl`) carried is here
    /// already as the start of the one carried: it has only gone on since.
    /// Then what is there is replaced or set aside; otherwise nothing is
    /// put. Another conversation's id, or a conversation that went another
    /// way here, is never written over.
    static func notComingBack(_ files: [(file: MigrationFile, carried: URL, there: URL?)]) -> String? {
        guard let taken = files.first(where: { $0.there != nil })?.there else { return nil }
        let logs = files.filter { !$0.file.packed && ($0.file.place as NSString).pathExtension == "jsonl" }
        let returning = !logs.isEmpty && logs.allSatisfy { log in log.there.map { isPrefix($0, of: log.carried) } == true }
        return returning ? nil : "\(taken.path) is here already, and is not this conversation come back further along"
    }

    /// The session a move (or a backup) carried, started here as `id` in
    /// `cwd` on the same conversation, its model and effort kept and its
    /// goal carried too (paused), told `notice`.
    func startCarried(_ offer: MigrationOffer, id: String, cwd: String, notice: String) -> SessionRecord? {
        var start = Envelope(type: "start")
        start.id = id
        start.agent = offer.session.agent
        start.cwd = cwd
        start.title = offer.session.title
        start.skipPermissions = offer.session.skipPermissions
        start.resume = offer.resumeID
        perform(start, from: nil)
        guard let record = session(id) else { return nil }
        record.setSettings(model: offer.session.model, effort: offer.session.effort)
        var said = notice
        if let goal = offer.session.goal, !goal.isEmpty, record.process.carryGoal(goal) {
            said += " Its goal came too, paused: /goal resume carries on with it."
        }
        broadcast(record.apply(.notice(said)), session: record)
        saveArchive()
        broadcastSessions()
        return record
    }

    /// Whether the file at `url` ends with `data`.
    static func endsWith(_ url: URL, _ data: Data) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = fileSize(url)
        guard size >= data.count, (try? handle.seek(toOffset: UInt64(size - data.count))) != nil else { return false }
        return (try? handle.read(upToCount: data.count)) == data
    }

    /// `path` from a computer whose home folder is `from`, on this one
    /// whose home folder is `to`: under the one, under the other (a
    /// backup's session's folder, restored here).
    static func path(_ path: String, from: String, to: String) -> String {
        guard !from.isEmpty else { return path }
        if path == from { return to }
        return path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
    }

    /// Why a session can't move here into `path`.
    static func notShared(_ path: String, shared: [String]) -> String {
        let folders = shared.isEmpty ? "none of its computer's folders" : "only " + shared.joined(separator: ", ")
        return "This server runs in a container that sees \(folders) of its computer's. A session here works in one of them, "
            + "or it would be on the container's own disk, which nothing else sees; \(path) is not in one. "
            + "Give the server a folder for each session in one (VISOR_SESSIONS_DIR)."
    }

    /// A session's id as clients make them: 24 letters and digits.
    static func newSessionID() -> String {
        String((0..<24).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// "340 KB", "12.5 MB", "1.3 GB".
    static func megabytes(_ bytes: Int) -> String {
        guard bytes >= 1 << 20 else { return "\(max(1, bytes >> 10)) KB" }
        let (unit, shift) = bytes >= 1 << 30 ? ("GB", 30) : ("MB", 20)
        let tenths = (bytes * 10 + (1 << (shift - 1))) >> shift
        return "\(tenths / 10).\(tenths % 10) \(unit)"
    }
}
