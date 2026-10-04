// The sessions written down and read back: sessions.json, what a launch
// carries on with, and the agents a previous life left behind.

import ClaudeTranscript
import MessageCache
import Foundation
import VisorProtocol

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
        var stored: [StoredSession] = []
        let legacy = Self.storeURL.deletingLastPathComponent().appendingPathComponent("archive.json")
        for url in [Self.storeURL, legacy] {
            guard let data = try? Data(contentsOf: url), data.count > 2 else { continue }
            do {
                var items = try JSONDecoder().decode([StoredSession].self, from: data)
                // Rows written before sizes were kept: read the sizes once
                // now, so an old thread lays out as steadily as a new one.
                for i in items.indices {
                    for j in items[i].entries.indices where items[i].entries[j].images.count > items[i].entries[j].imageSizes.count {
                        items[i].entries[j].imageSizes = AgentImages.pixelSizes(paths: items[i].entries[j].images)
                    }
                }
                stored += items.filter { item in !stored.contains { $0.info.id == item.info.id } }
            } catch {
                // A file we cannot read is not an empty one. Keep it, keep
                // quiet about nothing, and refuse to write over it: this is
                // the whole record of every session, and a decoding change
                // once turned it into "[]".
                let kept = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + ".unreadable")
                try? FileManager.default.removeItem(at: kept)
                try? FileManager.default.copyItem(at: url, to: kept)
                storeIsReadable = false
                lastError = "Could not read \(url.lastPathComponent): \(error). A copy is at \(kept.path); sessions are not being saved."
                return
            }
        }
        let asked = Self.requestedResumes()
        var orphans: [(session: String, pid: Int32, resume: String?)] = []
        for item in stored {
            var info = item.info
            info.busy = false
            info.ended = false
            // A terminal is drawn for a client that is no longer here.
            info.mode = .chat
            // An agent of ours that outlived the app (we were killed
            // outright, or quit before it went): it still holds the
            // session, so it goes before anything resumes into it.
            if let pid = item.agentPID { orphans.append((info.id, pid, item.resumeID)) }
            // Running when we went away, so running again now.
            if item.interrupted == true, !asked.contains("none"), asked.contains(info.id) || asked.contains("all") {
                pendingResumes.append(info.id)
            }
            var entries = item.entries
            if item.shape != StoredSession.currentShape, let resume = item.resumeID {
                let rebuilt = harnesses.harness(for: info.agent)?.transcript(id: resume, cwd: info.cwd, limit: 300) ?? []
                if !rebuilt.isEmpty { entries = rebuilt }
            }
            let record = SessionRecord(info: info, process: makeProcess(info, resume: item.resumeID), entries: entries,
                                       shownPrompts: item.shownPrompts ?? [], notice: item.notice)
            record.refreshResume()
            record.interrupted = item.interrupted ?? false
            // The outbox, lined up with its words (a file from before it was
            // kept has words and no files).
            let files = item.queuedImages ?? []
            record.queuedImages = info.queued.indices.map { $0 < files.count ? files[$0] : [] }
            record.primePreview()
            record.held = item.agentPID != nil
            sessions.append(record)
        }
        try? FileManager.default.removeItem(at: legacy)
        if !stored.isEmpty { saveArchive() }
        guard !orphans.isEmpty else { return }
        // Until its orphan is gone, what is said to a session waits.
        Task {
            for orphan in orphans {
                await Self.endOrphan(pid: orphan.pid, resume: orphan.resume)
                if let record = session(orphan.session) { release(record) }
            }
        }
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

    /// Writes every session down (the name is historical: it began as the
    /// archive).
    func saveArchive() {
        guard storeIsReadable else { return }
        let stored = sessions.map(\.stored)
        do {
            let data = try JSONEncoder().encode(stored)
            // Yesterday's file is kept beside today's. It costs nothing and
            // it is the difference between a bad write and a lost afternoon.
            let backup = Self.storeURL.deletingLastPathComponent().appendingPathComponent("sessions.previous.json")
            if let existing = try? Data(contentsOf: Self.storeURL), existing.count > 2, existing != data {
                try? existing.write(to: backup, options: .atomic)
            }
            try data.write(to: Self.storeURL, options: .atomic)
            if savingFailed {
                savingFailed = false
                lastError = nil
            }
        } catch {
            // Said in the menu, not swallowed: sessions that are not being
            // written down are lost at the next quit.
            savingFailed = true
            lastError = "Sessions are not being saved: \(error.localizedDescription)"
        }
    }
}
