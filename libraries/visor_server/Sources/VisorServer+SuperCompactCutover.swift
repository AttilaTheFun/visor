// Super Compact's review and cut-over (docs/super-compact.md): HANDOFF.md
// read and, as the person edits it, saved; then, once they choose Start
// New Session, the session that carries the work on started from it, and
// the one it came from archived (never deleted) with its mail forwarded.
//
//   GET  /api/sessions/<id>/super-compact/handoff   HANDOFF.md, as `text`
//   PUT  /api/sessions/<id>/super-compact/handoff   saved: `text`, at most handoffLimit
//   POST /api/sessions/<id>/super-compact/cutover   the new session (`session`, `sessions`)
//
// Admin-only, as every REST route is (VisorServer+Access). The cut-over
// is the server's, since only it can do every step together: it is
// allowed once the job is done and waiting for its review, never while the
// old session is mid-turn, and once.

import Foundation
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// The most a saved HANDOFF.md may be, in UTF-8 bytes.
    static let handoffLimit = 8 << 20

    /// The new session's first prompt: what it is, and HANDOFF.md read in
    /// full before anything else.
    static func continuingPrompt(title: String, id: String) -> String {
        "You're continuing session \"\(title)\" (\(id)). Read HANDOFF.md in this folder in full, in parts if it's long, "
            + "before anything else, and treat its rules and decisions as the person's own."
    }

    /// What the new session is called: the old one's title, continued.
    static func continuedTitle(_ title: String) -> String { title + " (continued)" }

    func restSuperCompactStep(_ call: RESTCall) -> HTTPResponse {
        guard let record = session(call.parts[1]) else { return HTTPResponse(404, Envelope.error("No such session").encoded()) }
        switch (call.request.method, call.parts[3]) {
        case ("GET", "handoff"): return superCompactHandoff(record)
        case ("PUT", "handoff"): return saveSuperCompactHandoff(record, text: call.body.text)
        case ("POST", "cutover"): return superCompactCutover(record)
        default: return HTTPResponse(404, "{\"error\":\"not found\"}")
        }
    }

    /// The session's job that is done, and its HANDOFF.md: or the refusal
    /// that says why there is none.
    private func doneSuperCompact(_ record: SessionRecord) -> Result<(job: SuperCompactJob, handoff: URL), HTTPResponse> {
        if let running = superCompaction, running.job.session == record.info.id, !running.job.phase.ended {
            return .failure(HTTPResponse(409, Envelope.error("The super compact of “\(record.displayName)” is still running: wait for it to finish.").encoded()))
        }
        guard let job = latestSuperCompactJob(of: record.info.id) else {
            return .failure(HTTPResponse(404, Envelope.error("“\(record.displayName)” has had no super compact.").encoded()))
        }
        guard job.phase == .done else {
            return .failure(HTTPResponse(409, Envelope.error("The last super compact of “\(record.displayName)” is \(job.phase.rawValue), not done.").encoded()))
        }
        let url = job.handoff.map { URL(fileURLWithPath: $0, isDirectory: false) }
            ?? job.folderURL.appendingPathComponent("HANDOFF.md", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(HTTPResponse(404, Envelope.error("HANDOFF.md of “\(record.displayName)” is not at \(url.path).").encoded()))
        }
        return .success((job, url))
    }

    func superCompactHandoff(_ record: SessionRecord) -> HTTPResponse {
        let done: (job: SuperCompactJob, handoff: URL)
        switch doneSuperCompact(record) {
        case .success(let found): done = found
        case .failure(let refusal): return refusal
        }
        guard let text = try? String(contentsOf: done.handoff, encoding: .utf8) else {
            return HTTPResponse(404, Envelope.error("HANDOFF.md of “\(record.displayName)” can't be read.").encoded())
        }
        var e = Envelope(type: "handoff")
        e.text = text
        e.path = done.handoff.path
        return .json(e.encoded())
    }

    /// The person's edits, saved in place of HANDOFF.md, and the check run
    /// again on them: only while the handoff waits for its review.
    func saveSuperCompactHandoff(_ record: SessionRecord, text: String?) -> HTTPResponse {
        guard let text else { return HTTPResponse(400, Envelope.error("Nothing to save: the handoff goes as `text`.").encoded()) }
        guard text.utf8.count <= Self.handoffLimit else {
            return HTTPResponse(413, Envelope.error("HANDOFF.md can be at most \(Self.megabytes(Self.handoffLimit)); this is \(Self.megabytes(text.utf8.count)).").encoded())
        }
        var done: (job: SuperCompactJob, handoff: URL)
        switch doneSuperCompact(record) {
        case .success(let found): done = found
        case .failure(let refusal): return refusal
        }
        guard done.job.awaitsReview else {
            return HTTPResponse(409, Envelope.error("The handoff of “\(record.displayName)” has been \(done.job.continuedAs == nil ? "discarded" : "started from") already.").encoded())
        }
        do {
            try Data(text.utf8).write(to: done.handoff, options: .atomic)
        } catch {
            return HTTPResponse(500, Envelope.error("HANDOFF.md could not be saved: \(error.localizedDescription)").encoded())
        }
        let ledger = (try? String(contentsOf: done.job.folderURL.appendingPathComponent("ledger.md", isDirectory: false), encoding: .utf8)) ?? ""
        if !ledger.isEmpty { done.job.warnings = SuperCompactCheck.warnings(ledger: ledger, handoff: text) }
        done.job.updated = Date().timeIntervalSince1970
        done.job.keep()
        Self.log("super compact \(done.job.id) of \(record.info.id): HANDOFF.md edited (\(text.utf8.count) bytes)")
        return .json(done.job.json)
    }

    /// The cut-over: a new session in a folder of its own, with the old
    /// one's agent, model, effort and permissions, HANDOFF.md and Claude's
    /// project memory in it, told to read HANDOFF.md first; then the old
    /// one archived, its mail forwarded, and each told of the other.
    func superCompactCutover(_ record: SessionRecord) -> HTTPResponse {
        var done: (job: SuperCompactJob, handoff: URL)
        switch doneSuperCompact(record) {
        case .success(let found): done = found
        case .failure(let refusal): return refusal
        }
        if let already = record.info.continuedAs ?? done.job.continuedAs {
            return HTTPResponse(409, Envelope.error("“\(record.displayName)” is continued as \(already) already.").encoded())
        }
        guard done.job.discarded == nil else {
            return HTTPResponse(409, Envelope.error("The handoff of “\(record.displayName)” was discarded: start a new super compact.").encoded())
        }
        guard !record.info.busy else {
            return HTTPResponse(409, Envelope.error("“\(record.displayName)” is in the middle of a turn: wait for it to finish, or stop it, then start the new session.").encoded())
        }
        guard let handoff = try? Data(contentsOf: done.handoff) else {
            return HTTPResponse(404, Envelope.error("HANDOFF.md of “\(record.displayName)” can't be read.").encoded())
        }
        let old = record.info
        let id = Self.newSessionID()
        let cwd = arrivalFolders.folder(agent: old.agent, id: id)
        // In a container, a session works in a folder its computer shares.
        if let shared = ServerPlatform.current.host.sharedFolders(), !shared.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) {
            return HTTPResponse(400, Envelope.error(Self.notShared(cwd, shared: shared)).encoded())
        }
        let files = FileManager.default
        if files.fileExists(atPath: cwd), (try? files.contentsOfDirectory(atPath: cwd))?.isEmpty != true {
            return HTTPResponse(409, Envelope.error("\(cwd), the new session's folder, is not empty.").encoded())
        }
        // (b) HANDOFF.md in the new folder; (c) Claude's memory under its project.
        do {
            try files.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            try handoff.write(to: URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent("HANDOFF.md", isDirectory: false), options: .atomic)
        } catch {
            return HTTPResponse(500, Envelope.error("The new session's folder could not be made: \(error.localizedDescription)").encoded())
        }
        let memory = old.agent == .claude ? Self.copyMemory(of: old, conversation: done.job.source, to: cwd) : nil
        // (a) The new session, as a client's start makes one, then given the
        // old one's model and effort and its whole title.
        var start = Envelope(type: "start")
        start.id = id
        start.agent = old.agent
        start.cwd = cwd
        start.title = Self.continuedTitle(record.displayName)
        start.skipPermissions = old.skipPermissions
        perform(start, from: nil)
        guard let next = session(id) else {
            return HTTPResponse(500, Envelope.error("The new session could not be started.").encoded())
        }
        next.setSettings(model: old.model, effort: old.effort)
        next.setTitle(Self.continuedTitle(record.displayName))
        // (g) Each names the other.
        next.info.continuedFrom = old.id
        record.info.continuedAs = id
        // (d) Its first prompt.
        deliver(Self.continuingPrompt(title: record.displayName, id: old.id), to: next)
        // (f) Its mail: what waits unread moves over, and what comes for the
        // old id from now on goes to the new one (forwardedSession).
        let moved = forwardInbox(from: record, to: next)
        // (e) The old one put away, never deleted.
        archive(record)
        done.job.continuedAs = id
        done.job.updated = Date().timeIntervalSince1970
        done.job.keep()
        Self.log("super compact \(done.job.id): “\(record.displayName)” (\(old.id)) continued as \(id) in \(cwd); "
            + "memory \(memory ?? "not copied"), \(moved) unread message\(moved == 1 ? "" : "s") moved")
        saveArchiveNow()
        broadcastSessions()
        var e = Envelope(type: "cutover")
        e.session = id
        e.cwd = cwd
        e.message = "Continued as “\(next.displayName)” in \(cwd). Claude's memory: \(memory ?? "none to copy"). "
            + "\(moved) unread message\(moved == 1 ? "" : "s") moved; mail for \(old.id) goes to \(id) from now on."
        e.sessions = sessions.map(\.info)
        return .json(e.encoded())
    }

    /// Claude's project memory for the old session (the `memory` folder
    /// beside its conversation, or under the project of its folder) copied
    /// under the project of `cwd`, unless that has one: what was copied, in
    /// words, or nil when there was none.
    static func copyMemory(of old: SessionInfo, conversation: String, to cwd: String) -> String? {
        let files = FileManager.default
        let beside = URL(fileURLWithPath: conversation, isDirectory: false).deletingLastPathComponent()
            .appendingPathComponent("memory", isDirectory: true)
        let candidates = [beside, memoryProject(old.cwd).appendingPathComponent("memory", isDirectory: true)]
        guard let source = candidates.first(where: { ((try? files.contentsOfDirectory(atPath: $0.path)) ?? []).isEmpty == false }) else {
            return nil
        }
        let project = memoryProject(cwd)
        let destination = project.appendingPathComponent("memory", isDirectory: true)
        if let there = try? files.contentsOfDirectory(atPath: destination.path), !there.isEmpty {
            log("the memory of \(old.title) not copied: \(destination.path) has one already")
            return "not copied (the new project has one)"
        }
        do {
            try files.createDirectory(at: project, withIntermediateDirectories: true)
            try? files.removeItem(at: destination)
            try files.copyItem(at: source, to: destination)
        } catch {
            log("the memory of \(old.title) could not be copied: \(error.localizedDescription)")
            return "not copied (\(error.localizedDescription))"
        }
        let count = ((try? files.contentsOfDirectory(atPath: destination.path)) ?? []).count
        return "copied (\(count) file\(count == 1 ? "" : "s"))"
    }

    /// The old session's unread mail moved to the new one's inbox,
    /// addressed to it, and its agent told: how many moved. What it has
    /// read stays where it is.
    func forwardInbox(from old: SessionRecord, to next: SessionRecord) -> Int {
        let unread = old.mailbox.inbox.filter(\.unread)
        guard !unread.isEmpty else { return 0 }
        let to = RelayEndpoint(server: id, serverName: hostName, session: next.info.id, sessionName: next.displayName)
        old.mailbox.inbox.removeAll(where: \.unread)
        for message in unread {
            var message = message
            message.to = to
            next.mailbox.receive(message)
        }
        notifyMail(next)
        return unread.count
    }

    /// The session mail for `id` goes to: itself, or, for one a Super
    /// Compact carried on, the session that carries it on now (along a
    /// chain of them, should that one have been carried on too).
    func forwardedSession(_ id: String?) -> String? {
        var current = id
        var seen: Set<String> = []
        while let at = current, seen.insert(at).inserted, let next = session(at)?.info.continuedAs, session(next) != nil {
            current = next
        }
        return current
    }
}
