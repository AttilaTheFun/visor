// The sessions written down and read back: the store (server.sqlite,
// SessionStore), what a launch carries on with, and the agents a previous
// life left behind.

import ClaudeTranscript
import MessageCache
import Foundation
import VisorAgent
import VisorProtocol
import VisorSystem

extension VisorServer {
    /// Which sessions this launch carries on with. Whatever was running
    /// when the app went away comes back running — that is the default and
    /// needs no argument. The launch list only narrows it:
    ///     open -a "Visor Server" --args --resume-sessions <id>,<id>
    ///     VISOR_RESUME=none "…/Visor Server.app/Contents/MacOS/Visor Server"
    /// ("all" is the default; "none" brings everything back idle instead.)
    static func requestedResumes() -> Set<String> {
        var raw = ProcessInfo.processInfo.environment["VISOR_RESUME"] ?? ""
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--resume-sessions"), arguments.index(after: flag) < arguments.endIndex {
            raw += "," + arguments[arguments.index(after: flag)]
        }
        let asked = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return asked.isEmpty ? ["all"] : asked
    }

    func loadSessions() {
        guard let stored = readStore() else { return }
        let asked = Self.requestedResumes()
        var orphans: [(session: String, pid: Int32, resume: String?)] = []
        var hosted: [(record: SessionRecord, host: StoredHost, pid: Int32?, resume: String?)] = []
        for item in stored {
            var info = item.info
            info.busy = false
            info.ended = false
            // A stopped agent stays stopped; one the app went away under
            // while it started or stopped is where it was going.
            switch info.agentState {
            case .stopped?, .stopping?: info.agentState = .stopped
            default: info.agentState = info.archived ? .stopped : .running
            }
            // What ran in the background ran in an agent that has gone
            // (an agent says its list when one changes, not when it
            // starts with none, so a kept list would stay up for good),
            // and so did its subagents. One left under its host may go on,
            // and its list with it (pickUp).
            if item.host == nil {
                info.background = []
                for index in info.subagents.indices { info.subagents[index].running = false }
            }
            // An agent of ours that outlived the app (we were killed
            // outright, or quit before it went): it still holds the
            // session, so it goes before anything resumes into it.
            // One left under its host is picked up instead (pickUp).
            if item.host == nil, let pid = item.agentPID { orphans.append((info.id, pid, item.resumeID)) }
            // Running when we went away, so running again now. Not a
            // driven session's: its agent runs on its runner, and went on
            // working while this server was away.
            if item.host == nil, item.driven != true, item.interrupted == true, !asked.contains("none"),
               asked.contains(info.id) || asked.contains("all") {
                pendingResumes.append(info.id)
            }
            var entries = item.entries
            if item.shape != StoredSession.currentShape, let resume = item.resumeID {
                let rebuilt = harnesses.harness(for: info.agent)?.transcript(id: resume, cwd: info.cwd, limit: SessionRecord.servedRows) ?? []
                if !rebuilt.isEmpty { entries = rebuilt }
            }
            // A session that ran in a container of its own (gone in 0.50):
            // its agent runs on this computer from now on.
            if let container = info.container {
                Self.log("session \(info.id) left its container \(container.id), which Visor no longer makes: its agent runs on this computer now")
                info.container = nil
            }
            // A contained session always auto-approves (VisorServer+Permissions).
            info = withPermissions(info)
            // A driven agent's process is its wrapper's stream, which comes
            // back when the wrapper dials again (VisorDriver). Until the
            // driver is there, one that starts nothing here: a driven
            // session never quietly becomes this computer's (visor#424).
            let driven = item.driven == true
            let process = driven ? (drivenProcess?(info) ?? AwaitingDriverProcess()) : makeProcess(info, resume: item.resumeID)
            let record = SessionRecord(info: info, process: process, entries: entries,
                                       shownPrompts: item.shownPrompts ?? [], notice: item.notice)
            record.driven = driven
            record.move = driven ? item.move : nil
            record.refreshResume()
            record.interrupted = item.interrupted ?? false
            record.reportedUsage = item.reportedUsage
            record.head = item.head
            record.leaf = item.leaf
            record.otherBranch = item.otherBranch
            record.branchKept = item.branchKept ?? false
            if let fork = item.fork { _ = record.startFork(fork) }
            record.watchedSubagents = Set(item.watchedSubagents ?? [])
            record.closedSubagents = Set(item.closedSubagents ?? [])
            record.mcpSwitched = item.mcpSwitched ?? [:]
            record.mailbox = item.mailbox ?? Mailbox()
            // An agent left running under its host has the MCP server of the
            // launch that started it, which may have no read_inbox.
            record.takesMail = item.host == nil
            // The outbox, lined up with its words (a file from before it was
            // kept has words and no files).
            let files = item.queuedImages ?? []
            record.queuedImages = info.queued.indices.map { $0 < files.count ? files[$0] : [] }
            // And where each came from; from before that was kept, told by
            // its words: mail by its form, the server's nudges by theirs.
            let origins = item.queuedOrigins ?? []
            record.queuedOrigins = info.queued.indices.map { $0 < origins.count ? origins[$0] : SessionRecord.origin(of: info.queued[$0]) }
            record.primePreview()
            record.held = item.agentPID != nil || item.host != nil
            if let host = item.host {
                record.leftHost = host
                hosted.append((record, host, item.agentPID, item.resumeID))
            }
            sessions.append(record)
        }
        if !stored.isEmpty { saveArchiveNow() }
        for left in hosted {
            Task { await pickUp(left.record, host: left.host, agentPID: left.pid, resume: left.resume) }
        }
        guard !orphans.isEmpty else { return }
        // Until its orphan is gone, what is said to a session waits.
        Task {
            for orphan in orphans {
                await Self.endOrphan(pid: orphan.pid, resume: orphan.resume)
                if let record = session(orphan.session) { release(record) }
            }
        }
    }

    /// The sessions as the store has them, pinned as their rows say
    /// (sessions.json's read into it first, the first time, and the pins
    /// messages.sqlite kept: VisorServer+SessionImport), and each one's row
    /// noted as written. Nil when there's no store to read: it couldn't be
    /// opened, or read, and nothing is written this launch (lastError says
    /// why).
    func readStore() -> [StoredSession]? {
        let name = Self.storeURL.lastPathComponent
        let store: SessionStore
        let rows: [SessionStore.Row]
        do {
            store = try SessionStore(path: Self.storeURL.path)
        } catch {
            refuseStore("Could not open \(name): \(error). Sessions are not being saved.")
            return nil
        }
        sessionStore = store
        guard importLegacyStore(into: store) else { return nil }
        movePinsFromCache(into: store)
        do {
            rows = try store.rows()
        } catch {
            refuseStore("Could not read \(name): \(error). Sessions are not being saved.")
            return nil
        }
        var stored: [StoredSession] = []
        var read: [String: SessionStore.Row] = [:]
        for row in rows where read[row.id] == nil {
            // A row we cannot read is kept, and so is every other: nothing
            // is written until a build that reads them all.
            guard var session = try? JSONDecoder().decode(StoredSession.self, from: Data(row.stored.utf8)) else {
                refuseStore("Could not read the session \(row.title) (\(row.id)) in \(name). Sessions are not being saved.")
                return nil
            }
            // Its pin is the row's (an archived session isn't pinned).
            session.info.pinned = row.pinned && !session.info.archived
            read[row.id] = row
            stored.append(session)
        }
        writtenRows = read
        // Rows written before sizes were kept: read the sizes once now, so
        // an old thread lays out as steadily as a new one.
        for i in stored.indices {
            for j in stored[i].entries.indices where stored[i].entries[j].images.count > stored[i].entries[j].imageSizes.count {
                stored[i].entries[j].imageSizes = AgentImages.pixelSizes(paths: stored[i].entries[j].images)
            }
        }
        return stored
    }

    /// Ends an agent left over from a previous life of the app. The pid
    /// alone is not trusted — pids are reused — so the process must still
    /// look like the agent it claims to be.
    @concurrent
    static func endOrphan(pid: Int32, resume: String?) async {
        let processes = ServerPlatform.current.processes
        guard pid > 1, processes.isRunning(pid) else { return }
        guard let command = await processes.commandLine(of: pid) else { return }
        guard command.contains("claude") || command.contains("codex") || command.contains("openrouter") else { return }
        if let resume, !resume.isEmpty, !command.contains(resume) { return }
        processes.terminate(pid)
        if await !Command.exited(pid, within: .seconds(2)) { processes.kill(pid) }
    }

    /// Writes the sessions down soon: once, `archiveSaveDelay` after the
    /// first change, with every change made by then. Most changes are of a
    /// turn (its state, its queue, mail read and sent), and a turn makes
    /// many; written on each, the store (megabytes, with the sessions'
    /// mailboxes) cost the Mac about a gigabyte an hour when it was
    /// sessions.json, written whole. What must survive a crash (a session
    /// made or ended, an agent's pid, archiving) is written at once with
    /// saveArchiveNow, as is everything before a quit or a relaunch.
    func saveArchive() {
        guard !archiveSavePending else { return }
        archiveSavePending = true
        let delay = archiveSaveDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.archiveSavePending else { return }
            self.saveArchiveNow()
        }
    }

    /// Writes the sessions down now (the name is historical: it began as
    /// the archive), and with them any change waiting to be: in one
    /// transaction, the rows of the sessions that changed since they were
    /// last written, the places and pins of those that moved in the list or
    /// were pinned or unpinned, and the rows of those gone. A session as it
    /// was is not written again.
    func saveArchiveNow() {
        archiveSavePending = false
        guard storeIsReadable, let store = sessionStore else { return }
        var put: [SessionStore.Row] = []
        var placed: [(id: String, position: Int, pinned: Bool)] = []
        var present: Set<String> = []
        do {
            for (position, record) in sessions.enumerated() {
                let session = record.stored
                guard present.insert(session.info.id).inserted else { continue }
                let encoded = try SessionStore.Row.encoded(session)
                if let written = writtenRows[session.info.id], written.stored == encoded {
                    if written.position != position || written.pinned != record.info.pinned {
                        placed.append((session.info.id, position, record.info.pinned))
                    }
                } else {
                    put.append(SessionStore.Row(session, encoded: encoded, position: position, pinned: record.info.pinned))
                }
            }
            let removed = writtenRows.keys.filter { !present.contains($0) }.sorted()
            if !put.isEmpty || !placed.isEmpty || !removed.isEmpty {
                try store.write(put: put, placed: placed, removed: removed)
                for row in put { writtenRows[row.id] = row }
                for place in placed {
                    writtenRows[place.id]?.position = place.position
                    writtenRows[place.id]?.pinned = place.pinned
                }
                for id in removed { writtenRows[id] = nil }
            }
            if savingFailed {
                savingFailed = false
                lastError = nil
            }
        } catch {
            // Said in the menu, not swallowed: sessions that are not being
            // written down are lost at the next quit.
            savingFailed = true
            lastError = "Sessions are not being saved: \(error)"
        }
    }
}
