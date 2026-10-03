// The sessions' agents (and terminal sessions' shells): made, bound to
// their records, given what the user says, rebuilt when a session's
// folder or settings change.

import AppKit
import ClaudeTranscript
import MessageCache
import Foundation
import Network
import VisorProtocol

extension VisorServer {
    func makeProcess(_ info: SessionInfo, resume: String?) -> AgentProcess {
        // The one harness for this agent makes and manages its process;
        // the server never branches on the agent itself.
        let harness = harnesses.harness(for: info.agent) ?? ClaudeHarness(kind: info.agent, tool: "claude", models: [])
        // The folder may have been renamed since this conversation began.
        // Put its history where the folder looks now, so both the agent
        // and a terminal can resume it from there.
        if let resume { harness.adoptHistory(id: resume, cwd: info.cwd) }
        let process = harness.makeProcess(cwd: info.cwd, skipPermissions: info.skipPermissions, resume: resume)
        // A shell is born at the window it is drawn for, so its first
        // prompt is already the right shape.
        if let size = info.mode.terminalSize { (process as? TerminalCapable)?.resize(cols: size.cols, rows: size.rows) }
        process.model = info.model
        process.effort = info.effort
        process.approvalEnvironment = ["VISOR_PORT": String(port), "VISOR_TOKEN": agentToken, "VISOR_SESSION": info.id]
        return process
    }

    /// Each provider's models: Claude's aliases and effort levels; Codex's
    /// from its models cache (~/.codex/models_cache.json, the listed ones)
    /// with the default from ~/.codex/config.toml.
    func catalogs() -> [AgentCatalog] { harnesses.all.map { $0.catalog() } }

    /// Points every session that ran in `from` at `to`. The agent holds
    /// its directory from the moment it spawns, so the process is rebuilt
    /// (resumed by its own id) — at once when idle, after the turn if not.
    @discardableResult
    func relocate(from: String, to: String) -> [SessionRecord] {
        let resolvedFrom = HostFolders.resolve(from)
        let moved = sessions.filter { HostFolders.resolve($0.info.cwd) == resolvedFrom }
        for record in moved {
            record.setCWD(to)
            guard !record.info.archived else { continue }
            if record.info.busy {
                record.restartWhenIdle = true
            } else {
                rebuild(record)
            }
        }
        if !moved.isEmpty {
            saveArchive()
            broadcastSessions()
        }
        return moved
    }

    func archive(_ record: SessionRecord) {
        record.process.stop()
        record.refreshResume()
        record.setArchived(true)
        record.restartWhenIdle = false
        // Archived means no process and nothing owed: it must not come back
        // running on the next launch.
        record.interrupted = false
        saveArchive()
        broadcast(record.transcriptEnvelope, session: record)
        broadcastSessions()
    }

    func unarchive(_ record: SessionRecord) {
        record.setArchived(false)
        saveArchive()
        broadcastSessions()
    }

    /// Carries on the turns that a restart interrupted. The agents are
    /// spawned by the send itself (resumed by their own id), so this is all
    /// it takes to bring a session back into a running state.
    func resumePending() {
        let ids = pendingResumes
        pendingResumes = []
        for id in ids {
            guard let record = session(id), !record.info.archived else { continue }
            deliver(Self.resumeNudge, to: record)
        }
        // What was waiting when the app went away goes now; behind a nudge
        // it waits for that turn to end, as any queued message does.
        for record in sessions where !record.info.archived && !record.info.queued.isEmpty && !record.info.busy {
            let waiting = record.takeQueue()
            deliver(waiting.text, to: record, images: waiting.images)
        }
        if !ids.isEmpty { broadcastSessions() }
    }

    /// Ends the agent and makes a new one on the same session, which
    /// picks the conversation up as the file stands: one built for the
    /// session as it is now (its folder, its settings). A turn in flight
    /// is cut short. A terminal session's shell starts again at once if a
    /// window has it; the chat's agent starts with the next message,
    /// which is when resuming matters. With `rereading`, the transcript is read again, since the
    /// file may have moved on under another writer.
    func rebuild(_ record: SessionRecord, rereading: Bool = false) {
        record.restartWhenIdle = false
        let old = record.process
        record.replaceProcess(makeProcess(record.info, resume: old.resumeID))
        // The old agent goes first: until it has, what is said waits.
        record.held = true
        // It is no longer heard, so its turn is ended here.
        if record.info.busy {
            broadcast(record.apply(.activity(nil)), session: record)
            handle(.busy(false), from: record)
        }
        Task {
            await old.end(within: .seconds(3))
            if record.info.mode.isTUI { launchTerminal(record) }
            if rereading { record.followFile() }
            release(record)
        }
    }

    /// The agent before this one is gone: what waited for that goes over.
    func release(_ record: SessionRecord) {
        record.held = false
        guard !record.info.archived, !record.info.busy, !record.info.queued.isEmpty else { return }
        let waiting = record.takeQueue()
        broadcastSessions()
        deliver(waiting.text, to: record, images: waiting.images)
    }

    /// A terminal session's shell is live before anything is typed: bound
    /// and started now (or kept, if it is running), at its window's size.
    func launchTerminal(_ record: SessionRecord) {
        if !record.isBound { bind(record) }
        if let size = record.info.mode.terminalSize { record.terminal?.resize(cols: size.cols, rows: size.rows) }
        do { try record.terminal?.start() } catch {
            broadcast(record.apply(.failure(error.localizedDescription)), session: record)
        }
        saveArchive()
    }

    func deliver(_ text: String, to record: SessionRecord, images: [String] = []) {
        // A terminal session has no turns: what is sent is a line typed
        // into its shell, and nothing is written down.
        if record.info.agent.isShell {
            if !record.isBound { bind(record) }
            do { try record.process.send(text) } catch {
                broadcast(record.apply(.failure(error.localizedDescription)), session: record)
            }
            return
        }
        // A turn in flight is left alone. What the user says now waits its
        // turn and goes over as soon as the agent falls idle — interrupting
        // is a deliberate act (`stop`), not the cost of typing.
        // Nor is anything said while the agent before this one is going.
        if record.info.busy || record.held {
            record.enqueue(text, images: images)
            saveArchive()
            broadcastSessions()
            return
        }
        record.appendUser(text, images: images)
        // Written down before the turn runs: if the app is killed while the
        // agent is working, the message the user sent is still here when it
        // comes back (the store is otherwise written at the end of a turn),
        // and `interrupted` says a reply is still owed.
        record.interrupted = true
        saveArchive()
        // The adapter's events reach subscribers through the record; bound
        // once, the first time the session takes a turn.
        if !record.isBound { bind(record) }
        var forAgent = text
        if !images.isEmpty {
            let list = images.map { "- " + $0 }.joined(separator: "\n")
            // Pictures by that name; with a video among them, files — the
            // agent reads a video by the tools it has, not as a picture.
            let pictures = images.allSatisfy { AgentImages.pixelSize(path: $0) != nil }
            let heading = pictures ? (images.count == 1 ? "Attached image:" : "Attached images:")
                                   : (images.count == 1 ? "Attached file:" : "Attached files:")
            forAgent = (text.isEmpty ? "" : text + "\n\n") + heading + "\n" + list
        }
        do {
            try record.process.send(forAgent)
            // The spawn happened inside `send`, so the pid is knowable
            // only now — and it is what finds this agent again if we are
            // killed outright.
            saveArchive()
            // Working from now, not from when the agent says so: what the
            // user sends next (a command after its words, split by the
            // client) waits for this turn rather than landing inside it.
            if !record.info.busy { broadcast(record.apply(.busy(true)), session: record) }
        } catch {
            broadcast(record.apply(.failure(error.localizedDescription)), session: record)
            broadcast(record.apply(.busy(false)), session: record)
            // Not where the tools usually are: the login shell is asked,
            // so the next try knows.
            if case AgentProcessError.toolMissing(let tool) = error { Task { await ToolPath.locate([tool]) } }
        }
    }

    func bind(_ record: SessionRecord) {
        record.onTerminalBytes = { [weak self, weak record] envelope in
            guard let self, let record, let controller = record.info.mode.controller else { return }
            for key in record.subscribers where self.connections[key]?.clientID == controller {
                self.connections[key]?.send(envelope)
            }
        }
        record.onFileRows = { [weak self, weak record] rows in
            guard let self, let record else { return }
            for row in rows { self.broadcast(.entry(session: record.info.id, row), session: record) }
        }
        record.onFileReplaced = { [weak self, weak record] in
            guard let self, let record else { return }
            self.broadcast(record.transcriptEnvelope, session: record)
            self.saveArchive()
        }
        record.onInfoChanged = { [weak self] in self?.broadcastSessionsSoon() }
        record.listen { [weak self, weak record] event in
            guard let self, let record else { return }
            self.handle(event, from: record)
        }
    }

    /// One thing an agent did: applied to its session's record, and told
    /// to whoever watches it.
    func handle(_ event: AgentEvent, from record: SessionRecord) {
        let reported = record.info.reportedModel
        // Nothing to say is nothing sent: terminal bytes went to the one
        // window they are drawn for inside apply.
        broadcast(record.apply(event), session: record)
        switch event {
        case .context, .session:
            // These land in the session list, not an envelope.
            broadcastSessions()
        case .model:
            if record.info.reportedModel != reported { broadcastSessions() }
        case .commands(let list):
            keepCommands(list, for: record.info.agent)
        case .busy(let busy):
            // The turn's status lines, whole, whenever they change.
            if !busy { broadcast(.status(session: record.info.id, items: []), session: record) }
            if !busy, !record.approvalWaiters.isEmpty {
                for waiter in record.approvalWaiters.values { waiter.close() }
                record.approvalWaiters.removeAll()
            }
            // The agent's own id appears with the first turn; the
            // transcript is written down whenever a turn ends.
            record.refreshResume()
            if !busy { record.interrupted = false; saveArchive() }
            broadcastSessions()
            // An archived session takes no turns, and one whose last
            // agent is still going waits for it.
            guard !busy, !record.info.archived, !record.held else { return }
            if record.restartWhenIdle {
                // Rebuilt rather than merely stopped: a flag the agent
                // takes at launch (its permission mode, its model)
                // survives a restart of the same object, but its
                // directory does not — that is fixed when the process is
                // made. What waited goes over once the old agent is gone.
                rebuild(record)
            } else if !record.info.queued.isEmpty {
                // Everything said during the turn goes over as one turn,
                // in the order it was said.
                let waiting = record.takeQueue()
                broadcastSessions()
                deliver(waiting.text, to: record, images: waiting.images)
            }
        default:
            break
        }
    }

    func session(_ id: String?) -> SessionRecord? {
        sessions.first { $0.info.id == id }
    }
}
